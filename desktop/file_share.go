package main

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"log"
	"mime"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
)

const fileShareDuration = 30 * time.Minute

type sharedFile struct {
	path      string
	name      string
	info      os.FileInfo
	expiresAt time.Time
	etag      string
}

type fileShares struct {
	mu     sync.Mutex
	byCode map[string]sharedFile
}

func (s *fileShares) add(code string, file sharedFile, now time.Time) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.byCode == nil {
		s.byCode = make(map[string]sharedFile)
	}
	for key, item := range s.byCode {
		if !now.Before(item.expiresAt) {
			delete(s.byCode, key)
		}
	}
	s.byCode[code] = file
}

func (s *fileShares) find(code string, now time.Time) (sharedFile, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	file, ok := s.byCode[code]
	if ok && !now.Before(file.expiresAt) {
		delete(s.byCode, code)
		ok = false
	}
	return file, ok
}

func sameSharedFile(before, now os.FileInfo) bool {
	return now.Mode().IsRegular() && os.SameFile(before, now) &&
		before.Size() == now.Size() && before.ModTime().Equal(now.ModTime())
}

func (file sharedFile) open() (*os.File, error) {
	current, err := os.Stat(file.path)
	if err != nil {
		return nil, err
	}
	if !sameSharedFile(file.info, current) {
		return nil, errors.New("shared file changed")
	}
	source, err := os.Open(file.path)
	if err != nil {
		return nil, err
	}
	opened, err := source.Stat()
	if err != nil || !sameSharedFile(file.info, opened) {
		source.Close()
		return nil, errors.New("shared file changed")
	}
	return source, nil
}

func (s *relay) createFileShare(w http.ResponseWriter, r *http.Request) {
	if !s.dashboardActionAllowed(r) {
		writeError(w, http.StatusForbidden, "dashboard origin required")
		return
	}
	var request struct {
		Address string `json:"address"`
		Path    string `json:"path"`
	}
	if err := readSmallJSON(w, r, &request); err != nil || !filepath.IsAbs(request.Path) {
		writeError(w, http.StatusBadRequest, "请选择文件或输入完整文件路径。")
		return
	}
	if !slices.Contains(advertiseAddresses(s.listening, s.scheme), request.Address) {
		writeError(w, http.StatusBadRequest, "请选择有效的局域网接收地址。")
		return
	}

	path := filepath.Clean(request.Path)
	info, err := os.Stat(path)
	if err != nil || !info.Mode().IsRegular() {
		writeError(w, http.StatusBadRequest, "无法读取所选文件。请选择可读取的普通文件。")
		return
	}
	name := sanitizeName(filepath.Base(path), false)
	if name == "" {
		name = "download"
	}
	code := newPairingSecret()
	now := time.Now()
	digest := sha256.Sum256([]byte(code))
	file := sharedFile{
		path: path, name: name, info: info,
		expiresAt: now.Add(fileShareDuration), etag: `"` + hex.EncodeToString(digest[:]) + `"`,
	}
	source, err := file.open()
	if err != nil {
		writeError(w, http.StatusBadRequest, "无法读取所选文件。请重新选择。")
		return
	}
	source.Close()

	image, err := transferQRCode("download", request.Address, code)
	if err != nil {
		log.Printf("生成文件下载码失败 %v", err)
		writeError(w, http.StatusInternalServerError, "无法生成文件下载码。")
		return
	}
	s.shares.add(code, file, now)
	writeJSON(w, http.StatusOK, struct {
		Image     string    `json:"image"`
		ExpiresAt time.Time `json:"expiresAt"`
		Name      string    `json:"name"`
		Size      int64     `json:"size"`
	}{
		Image: image, ExpiresAt: file.expiresAt.UTC(), Name: file.name, Size: file.info.Size(),
	})
}

func (s *relay) downloadSharedFile(w http.ResponseWriter, r *http.Request) {
	code, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || code == "" {
		writeError(w, http.StatusUnauthorized, "a download code is required")
		return
	}
	file, ok := s.shares.find(code, time.Now())
	if !ok {
		writeError(w, http.StatusGone, "download code expired or unavailable")
		return
	}
	source, err := file.open()
	if err != nil {
		writeError(w, http.StatusGone, "shared file changed or unavailable")
		return
	}
	defer source.Close()

	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Disposition", mime.FormatMediaType("attachment", map[string]string{"filename": file.name}))
	w.Header().Set("X-Filename", url.PathEscape(file.name))
	w.Header().Set("ETag", file.etag)
	http.ServeContent(w, r, file.name, file.info.ModTime(), source)
}
