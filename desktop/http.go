package main

import (
	"context"
	"crypto/subtle"
	"encoding/json"
	"errors"
	"io"
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
	"sync/atomic"
	"time"
)

const (
	uploadDuration     = 45 * time.Minute
	uploadIdleTime     = 90 * time.Second
	diagnosticKind     = "diagnostic"
	diagnosticType     = "text/plain"
	maxDiagnosticBytes = 1 << 20
)

type uploadStream struct {
	body       io.Reader
	connection *http.ResponseController
	hardLimit  time.Time
	refreshAt  time.Time
}

func (s *uploadStream) Read(p []byte) (int, error) {
	now := time.Now()
	if !now.Before(s.refreshAt) {
		deadline := now.Add(uploadIdleTime)
		if s.hardLimit.Before(deadline) {
			deadline = s.hardLimit
		}
		// Some wrapped response writers do not expose the connection deadline.
		// The server-level timeout still applies to those requests.
		_ = s.connection.SetReadDeadline(deadline)
		s.refreshAt = now.Add(time.Second)
	}
	return s.body.Read(p)
}

type relay struct {
	locations     *receiveLocations
	pickingPath   atomic.Bool
	token         string
	pairings      *pairingRegistry
	shares        fileShares
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
	mux.HandleFunc("POST /api/v1/pair", s.pairDevice)
	mux.HandleFunc("GET /api/v1/download", s.downloadSharedFile)
	return mux
}

func (s *relay) upload(w http.ResponseWriter, r *http.Request) {
	token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	if !ok || (subtle.ConstantTimeCompare([]byte(token), []byte(s.token)) != 1 && !s.pairings.accepts(token)) {
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
	maxBytes := s.maxBytes
	if kind == diagnosticKind {
		maxBytes = min(s.maxBytes, maxDiagnosticBytes)
		if r.ContentLength > maxBytes {
			writeError(w, http.StatusRequestEntityTooLarge, "diagnostic exceeds configured size limit")
			return
		}
		contentType, _, err := mime.ParseMediaType(r.Header.Get("Content-Type"))
		if err != nil || contentType != diagnosticType {
			writeError(w, http.StatusUnsupportedMediaType, "diagnostic must use Content-Type: text/plain")
			return
		}
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

	stream := &uploadStream{
		body:       http.MaxBytesReader(w, r.Body, maxBytes),
		connection: http.NewResponseController(w),
		hardLimit:  time.Now().Add(uploadDuration),
	}
	store, finish := s.locations.openUpload(uploadID)
	defer finish()
	record, created, err := store.save(stream, r.ContentLength, uploadID, name, kind)
	switch {
	case errors.Is(err, errUploadTimeout):
		w.Header().Set("Retry-After", "5")
		writeError(w, http.StatusServiceUnavailable, err.Error())
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
	return kind == "screenshot" || kind == "screen-recording" || kind == diagnosticKind
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
	switch kind {
	case "screenshot":
		return screenshotTypes[ext]
	case "screen-recording":
		return recordingTypes[ext]
	case diagnosticKind:
		if ext == ".txt" {
			return diagnosticType + "; charset=utf-8"
		}
	}
	return ""
}

type recentFile struct {
	Name       string    `json:"name"`
	Kind       string    `json:"kind"`
	Size       int64     `json:"size"`
	ReceivedAt time.Time `json:"receivedAt"`
	URL        string    `json:"url"`
}

type dashboardStatus struct {
	Version   string                `json:"version"`
	Listening bool                  `json:"listening"`
	Addresses []string              `json:"addresses"`
	Token     string                `json:"token"`
	Folder    string                `json:"folder"`
	Recent    []recentFile          `json:"recent"`
	Devices   []pairedDeviceSummary `json:"devices"`
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
	mux.HandleFunc("POST /api/pairing", s.showPairingQR)
	mux.HandleFunc("POST /api/folder", s.changeReceiveFolder)
	mux.HandleFunc("POST /api/folder/pick", s.pathPicker(func(ctx context.Context) (string, error) {
		return pickReceiveFolder(ctx, s.locations.current().root)
	}))
	mux.HandleFunc("POST /api/file-share", s.createFileShare)
	mux.HandleFunc("POST /api/file-share/pick", s.pathPicker(pickShareFile))
	mux.HandleFunc("GET /files/{id}", s.serveCapture)
	mux.HandleFunc("POST /api/open-folder", func(w http.ResponseWriter, r *http.Request) {
		if !s.dashboardActionAllowed(r) {
			writeError(w, http.StatusForbidden, "dashboard origin required")
			return
		}
		if err := openDesktop(s.locations.current().root, true); err != nil {
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

func (s *relay) dashboardActionAllowed(r *http.Request) bool {
	return r.Header.Get("X-ScreenRelay") == "1" &&
		r.Header.Get("Origin") == "http://"+s.dashboardHost
}

func (s *relay) changeReceiveFolder(w http.ResponseWriter, r *http.Request) {
	if !s.dashboardActionAllowed(r) {
		writeError(w, http.StatusForbidden, "dashboard origin required")
		return
	}
	var request struct {
		Path string `json:"path"`
	}
	if err := readSmallJSON(w, r, &request); err != nil || !filepath.IsAbs(request.Path) {
		writeError(w, http.StatusBadRequest, "请输入完整的保存路径，或选择文件夹。")
		return
	}
	folder, err := s.locations.change(request.Path)
	if err != nil {
		writeError(w, http.StatusBadRequest, "无法修改保存位置。"+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"folder": folder})
}

func (s *relay) pathPicker(pick func(context.Context) (string, error)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.dashboardActionAllowed(r) {
			writeError(w, http.StatusForbidden, "dashboard origin required")
			return
		}
		if !s.pickingPath.CompareAndSwap(false, true) {
			writeError(w, http.StatusConflict, "系统选择窗口已打开。")
			return
		}
		defer s.pickingPath.Store(false)
		path, err := pick(r.Context())
		if r.Context().Err() != nil {
			return
		}
		if err != nil {
			writeError(w, http.StatusInternalServerError, err.Error())
			return
		}
		if path == "" {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"path": path})
	}
}

func (s *relay) status(w http.ResponseWriter, r *http.Request) {
	recent := []recentFile{}
	for _, record := range s.locations.recent(40) {
		recent = append(recent, recentFile{
			Name: record.Name, Kind: record.Kind, Size: record.Size,
			ReceivedAt: record.ReceivedAt, URL: "/files/" + record.ID,
		})
	}
	writeJSON(w, http.StatusOK, dashboardStatus{
		Version: version, Listening: true, Addresses: advertiseAddresses(s.listening, s.scheme),
		Token: s.token, Folder: s.locations.current().root, Recent: recent, Devices: s.pairings.summaries(),
	})
}

func (s *relay) serveCapture(w http.ResponseWriter, r *http.Request) {
	record, store, ok := s.locations.find(r.PathValue("id"))
	if !ok {
		http.NotFound(w, r)
		return
	}
	file, err := os.Open(record.path(store.root))
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
