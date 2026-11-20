package main

import (
	"crypto/subtle"
	"encoding/json"
	"errors"
	"log"
	"mime"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type relay struct {
	store         *captureStore
	token         string
	maxBytes      int64
	uploads       chan struct{}
	scheme        string
	listening     *net.TCPAddr
	dashboardHost string
}

var uploadIDPattern = regexp.MustCompile(`^[A-Za-z0-9._-]{1,128}$`)

func (s *relay) phoneAPI() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/v1/health", func(w http.ResponseWriter, r *http.Request) {
		writeJSON(w, http.StatusOK, map[string]string{"status": "ok", "version": version})
	})
	mux.HandleFunc("POST /api/v1/uploads", s.upload)
	return mux
}

func (s *relay) upload(w http.ResponseWriter, r *http.Request) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || subtle.ConstantTimeCompare([]byte(token), []byte(s.token)) != 1 {
		w.Header().Set("WWW-Authenticate", `Bearer realm="ScreenRelay"`)
		writeError(w, http.StatusUnauthorized, "invalid pairing code")
		return
	}
	if r.ContentLength < 0 {
		writeError(w, http.StatusLengthRequired, "Content-Length required")
		return
	}
	if r.ContentLength == 0 {
		writeError(w, http.StatusBadRequest, "empty capture")
		return
	}
	if r.ContentLength > s.maxBytes {
		writeError(w, http.StatusRequestEntityTooLarge, "capture exceeds configured size limit")
		return
	}

	kind := r.Header.Get("X-Media-Kind")
	if !validKind(kind) {
		writeError(w, http.StatusBadRequest, "unknown X-Media-Kind")
		return
	}
	rawName, err := url.PathUnescape(r.Header.Get("X-Filename"))
	name := sanitizeName(rawName)
	if err != nil || name == "" {
		writeError(w, http.StatusBadRequest, "invalid X-Filename")
		return
	}
	mediaType := captureMediaType(name, kind)
	if mediaType == "" {
		writeError(w, http.StatusUnsupportedMediaType, "unsupported capture extension")
		return
	}
	uploadID := r.Header.Get("X-Upload-Id")
	if uploadID != "" && !uploadIDPattern.MatchString(uploadID) {
		writeError(w, http.StatusBadRequest, "invalid X-Upload-Id")
		return
	}

	select {
	case s.uploads <- struct{}{}:
		defer func() { <-s.uploads }()
	default:
		w.Header().Set("Retry-After", "5")
		writeError(w, http.StatusServiceUnavailable, "receiver is busy")
		return
	}

	record, created, err := s.store.save(http.MaxBytesReader(w, r.Body, s.maxBytes),
		r.ContentLength, uploadID, name, kind)
	switch {
	case errors.Is(err, errIDConflict):
		writeError(w, http.StatusConflict, err.Error())
	case errors.Is(err, errIncomplete):
		writeError(w, http.StatusBadRequest, err.Error())
	case err != nil:
		log.Printf("保存接收文件失败 %v", err)
		writeError(w, http.StatusInternalServerError, "failed to save capture")
	default:
		status := http.StatusOK
		if created {
			status = http.StatusCreated
		}
		writeJSON(w, status, map[string]string{"id": record.ID, "name": record.Name})
	}
}

func validKind(kind string) bool {
	return kind == "screenshot" || kind == "screen-recording"
}

var screenshotTypes = map[string]string{
	".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
	".webp": "image/webp", ".heic": "image/heic", ".heif": "image/heif",
	".avif": "image/avif", ".gif": "image/gif", ".bmp": "image/bmp",
	".jxl": "image/jxl", ".tif": "image/tiff", ".tiff": "image/tiff",
}

var recordingTypes = map[string]string{
	".mp4": "video/mp4", ".mov": "video/quicktime", ".m4v": "video/mp4",
	".webm": "video/webm", ".mkv": "video/x-matroska", ".3gp": "video/3gpp",
}

func captureMediaType(name, kind string) string {
	ext := strings.ToLower(filepath.Ext(name))
	if kind == "screenshot" {
		return screenshotTypes[ext]
	}
	return recordingTypes[ext]
}

type recentFile struct {
	Name       string    `json:"name"`
	Kind       string    `json:"kind"`
	Size       int64     `json:"size"`
	ReceivedAt time.Time `json:"receivedAt"`
	URL        string    `json:"url"`
}

type dashboardStatus struct {
	Version   string       `json:"version"`
	Listening bool         `json:"listening"`
	Addresses []string     `json:"addresses"`
	Token     string       `json:"token"`
	Folder    string       `json:"folder"`
	Recent    []recentFile `json:"recent"`
}

func (s *relay) dashboardAPI() http.Handler {
	mux := http.NewServeMux()
	for route, filename := range map[string]string{
		"/": "index.html", "/style.css": "style.css", "/app.js": "app.js",
	} {
		if route == "/" {
			route = "/{$}"
		}
		mux.HandleFunc("GET "+route, func(w http.ResponseWriter, r *http.Request) {
			http.ServeFileFS(w, r, dashboard, "ui/"+filename)
		})
	}
	mux.HandleFunc("GET /api/status", s.status)
	mux.HandleFunc("GET /files/{id}", s.serveCapture)
	mux.HandleFunc("POST /api/open-folder", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("X-ScreenRelay") != "1" ||
			r.Header.Get("Origin") != "http://"+s.dashboardHost {
			writeError(w, http.StatusForbidden, "dashboard origin required")
			return
		}
		if err := openDesktop(s.store.root, true); err != nil {
			writeError(w, http.StatusInternalServerError, "无法打开保存目录")
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		host, _, _ := net.SplitHostPort(r.RemoteAddr)
		ip := net.ParseIP(host)
		if r.Host != s.dashboardHost || ip == nil || !ip.IsLoopback() {
			http.Error(w, "local dashboard only", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Referrer-Policy", "no-referrer")
		w.Header().Set("Cross-Origin-Resource-Policy", "same-origin")
		w.Header().Set("Content-Security-Policy",
			"default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; media-src 'self'; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'")
		mux.ServeHTTP(w, r)
	})
}

func (s *relay) status(w http.ResponseWriter, r *http.Request) {
	recent := []recentFile{}
	for _, record := range s.store.recent(40) {
		recent = append(recent, recentFile{
			Name: record.Name, Kind: record.Kind, Size: record.Size,
			ReceivedAt: record.ReceivedAt, URL: "/files/" + record.ID,
		})
	}
	writeJSON(w, http.StatusOK, dashboardStatus{
		Version: version, Listening: true, Addresses: advertiseAddresses(s.listening, s.scheme),
		Token: s.token, Folder: s.store.root, Recent: recent,
	})
}

func (s *relay) serveCapture(w http.ResponseWriter, r *http.Request) {
	record, ok := s.store.get(r.PathValue("id"))
	if !ok || !existingFile(record, s.store.root) {
		http.NotFound(w, r)
		return
	}
	file, err := os.Open(record.path(s.store.root))
	if err != nil {
		http.NotFound(w, r)
		return
	}
	defer file.Close()

	mediaType := captureMediaType(record.Name, record.Kind)
	disposition := "attachment"
	switch mediaType {
	case "image/png", "image/jpeg", "image/gif", "image/webp", "image/avif",
		"video/mp4", "video/quicktime", "video/webm":
		if r.URL.Query().Get("download") != "1" {
			disposition = "inline"
		}
	}
	if mediaType == "" {
		mediaType = "application/octet-stream"
	}
	w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
	w.Header().Set("Content-Type", mediaType)
	w.Header().Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": record.Name}))
	w.Header().Set("ETag", strconv.Quote(record.ContentSHA))
	http.ServeContent(w, r, record.Name, record.ReceivedAt, file)
}

func writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(status)
	if err := json.NewEncoder(w).Encode(value); err != nil {
		log.Printf("写入 HTTP 响应失败 %v", err)
	}
}

func writeError(w http.ResponseWriter, status int, message string) {
	writeJSON(w, status, map[string]string{"error": message})
}
