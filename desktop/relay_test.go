package main

import (
	"bytes"
	"encoding/json"
	"io"
	"mime"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func testRelay(t *testing.T, folder string) *relay {
	t.Helper()
	locations, err := loadReceiveLocations(filepath.Join(folder, "receive-locations.json"), folder, "")
	if err != nil {
		t.Fatal(err)
	}
	pairings, err := loadPairings(filepath.Join(folder, "paired-devices.json"))
	if err != nil {
		t.Fatal(err)
	}
	return &relay{
		locations: locations, token: "test-pairing-token", pairings: pairings, maxBytes: 1024,
		uploads: make(chan struct{}, 4), scheme: "http",
		listening:     &net.TCPAddr{IP: net.IPv4(192, 168, 0, 1), Port: 8765},
		dashboardHost: "127.0.0.1:40000",
	}
}

func sendCapture(s *relay, id, name, kind string, payload []byte) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, "/api/v1/uploads", bytes.NewReader(payload))
	request.Header.Set("Authorization", "Bearer "+s.token)
	request.Header.Set("X-Upload-Id", id)
	request.Header.Set("X-Filename", url.PathEscape(name))
	request.Header.Set("X-Media-Kind", kind)
	response := httptest.NewRecorder()
	s.phoneAPI().ServeHTTP(response, request)
	return response
}

func localRequest(s *relay, path string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodGet, "http://"+s.dashboardHost+path, nil)
	request.RemoteAddr = "127.0.0.1:40001"
	response := httptest.NewRecorder()
	s.dashboardAPI().ServeHTTP(response, request)
	return response
}

func TestUploadAndReplayAfterRestart(t *testing.T) {
	folder := t.TempDir()
	service := testRelay(t, folder)
	name := "截屏 10+20.png"
	payload := []byte("test screenshot payload")
	result := sendCapture(service, "device.capture-1", name, "screenshot", payload)
	if result.Code != http.StatusCreated {
		t.Fatalf("upload got %d: %s", result.Code, result.Body)
	}

	service = testRelay(t, folder)
	result = sendCapture(service, "device.capture-1", name, "screenshot", payload)
	if result.Code != http.StatusOK {
		t.Fatalf("replay got %d: %s", result.Code, result.Body)
	}
	result = sendCapture(service, "device.capture-1", name, "screenshot", []byte("different"))
	if result.Code != http.StatusConflict {
		t.Fatalf("conflict got %d: %s", result.Code, result.Body)
	}
	result = sendCapture(service, "device.capture-2", "新录屏.mov", "screen-recording", []byte("video"))
	if result.Code != http.StatusCreated {
		t.Fatalf("recording got %d: %s", result.Code, result.Body)
	}

	status := localRequest(service, "/api/status")
	var configuration dashboardStatus
	if err := json.Unmarshal(status.Body.Bytes(), &configuration); err != nil {
		t.Fatal(err)
	}
	if configuration.Token != service.token || len(configuration.Recent) != 2 ||
		configuration.Recent[0].Kind != "screen-recording" || configuration.Recent[1].Name != name {
		t.Fatalf("unexpected dashboard status: %+v", configuration)
	}
	item := configuration.Recent[1]
	download := localRequest(service, item.URL+"?download=1")
	if !bytes.Equal(download.Body.Bytes(), payload) ||
		!strings.HasPrefix(download.Header().Get("Content-Disposition"), "attachment") {
		t.Fatalf("unexpected download: %d, %v", download.Code, download.Header())
	}
	preview := localRequest(service, item.URL)
	if preview.Header().Get("Content-Type") != "image/png" ||
		!strings.HasPrefix(preview.Header().Get("Content-Disposition"), "inline") {
		t.Fatalf("unexpected preview: %d, %v", preview.Code, preview.Header())
	}

	records := service.locations.recent(40)
	if err := os.Remove(records[1].path(folder)); err != nil {
		t.Fatal(err)
	}
	if response := localRequest(service, item.URL); response.Code != http.StatusNotFound {
		t.Fatalf("deleted download returned %d", response.Code)
	}
	if retry := sendCapture(service, "device.capture-1", name, "screenshot", payload); retry.Code != http.StatusCreated {
		t.Fatalf("retry for removed file returned %d", retry.Code)
	}
}

func TestDiagnosticUploadAndDownloadAfterRestart(t *testing.T) {
	folder := t.TempDir()
	service := testRelay(t, folder)
	name := "Crash-测试.TXT"
	payload := []byte("<script>alert('text only')</script>\n崩溃日志\n")
	upload := func(service *relay, kind, name, mediaType string, length int64) *httptest.ResponseRecorder {
		request := httptest.NewRequest(http.MethodPost, "/api/v1/uploads", bytes.NewReader(payload))
		request.ContentLength = length
		request.Header.Set("Authorization", "Bearer "+service.token)
		request.Header.Set("Content-Type", mediaType)
		request.Header.Set("X-Filename", url.PathEscape(name))
		request.Header.Set("X-Media-Kind", kind)
		request.Header.Set("X-Upload-Id", "device.diagnostic-1")
		response := httptest.NewRecorder()
		service.phoneAPI().ServeHTTP(response, request)
		return response
	}
	length := int64(len(payload))
	for _, tc := range []struct {
		name, kind, mediaType string
		length                int64
		want                  int
	}{
		{"Crash-report.html", diagnosticKind, "text/plain", length, http.StatusUnsupportedMediaType},
		{name, diagnosticKind, "text/html", length, http.StatusUnsupportedMediaType},
		{name, "screenshot", "text/plain", length, http.StatusUnsupportedMediaType},
		{name, diagnosticKind, "text/plain; charset=utf-8", length, http.StatusCreated},
	} {
		if response := upload(service, tc.kind, tc.name, tc.mediaType, tc.length); response.Code != tc.want {
			t.Fatalf("upload %q as %s/%s: got %d, want %d: %s", tc.name, tc.kind, tc.mediaType,
				response.Code, tc.want, response.Body)
		}
	}
	service.maxBytes = 2 * maxDiagnosticBytes
	if response := upload(service, diagnosticKind, name, "text/plain", maxDiagnosticBytes+1); response.Code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize diagnostic upload got %d: %s", response.Code, response.Body)
	}

	service = testRelay(t, folder)
	if retry := upload(service, diagnosticKind, name, "text/plain", length); retry.Code != http.StatusOK {
		t.Fatalf("diagnostic retry got %d: %s", retry.Code, retry.Body)
	}
	status := localRequest(service, "/api/status")
	var dashboard dashboardStatus
	if err := json.Unmarshal(status.Body.Bytes(), &dashboard); err != nil {
		t.Fatal(err)
	}
	if len(dashboard.Recent) != 1 || dashboard.Recent[0].Kind != diagnosticKind || dashboard.Recent[0].Name != name {
		t.Fatalf("unexpected diagnostic history: %+v", dashboard.Recent)
	}
	response := localRequest(service, dashboard.Recent[0].URL)
	disposition, params, err := mime.ParseMediaType(response.Header().Get("Content-Disposition"))
	if response.Code != http.StatusOK || err != nil || disposition != "attachment" || params["filename"] != name ||
		response.Header().Get("Content-Type") != "text/plain; charset=utf-8" ||
		response.Header().Get("X-Content-Type-Options") != "nosniff" || !bytes.Equal(response.Body.Bytes(), payload) {
		t.Fatalf("unexpected diagnostic download: %d, %v, %q", response.Code, response.Header(), response.Body)
	}
}

func TestUploadValidationAndIsolation(t *testing.T) {
	service := testRelay(t, t.TempDir())
	for _, tc := range []struct {
		name       string
		header     string
		change     string
		want       int
		length     int64
		bodyLength int
	}{
		{name: "unauthorized", header: "Authorization", change: "Bearer wrong", want: 401, length: 12, bodyLength: 12},
		{name: "too large", want: 413, length: 2048, bodyLength: 12},
		{name: "unknown size", want: 411, length: -1, bodyLength: 12},
		{name: "truncated", want: 400, length: 12, bodyLength: 6},
		{name: "unsafe extension", header: "X-Filename", change: "file.svg", want: 415, length: 12, bodyLength: 12},
		{name: "invalid ID", header: "X-Upload-Id", change: "other/id", want: 400, length: 12, bodyLength: 12},
	} {
		t.Run(tc.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/api/v1/uploads",
				bytes.NewReader(make([]byte, tc.bodyLength)))
			request.ContentLength = tc.length
			request.Header.Set("Authorization", "Bearer "+service.token)
			request.Header.Set("X-Filename", "file.png")
			request.Header.Set("X-Media-Kind", "screenshot")
			if tc.header != "" {
				request.Header.Set(tc.header, tc.change)
			}
			response := httptest.NewRecorder()
			service.phoneAPI().ServeHTTP(response, request)
			if response.Code != tc.want {
				t.Fatalf("got %d, want %d: %s", response.Code, tc.want, response.Body)
			}
		})
	}
	entries, err := os.ReadDir(filepath.Join(service.locations.current().root, stateDirectory))
	if err != nil || len(entries) != 0 {
		t.Fatalf("failed requests left partial files: %v %v", entries, err)
	}

	response := httptest.NewRecorder()
	service.phoneAPI().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/status", nil))
	if response.Code != http.StatusNotFound {
		t.Fatalf("LAN listener exposed dashboard status: %d", response.Code)
	}
	request := httptest.NewRequest(http.MethodGet, "http://different.example/api/status", nil)
	request.RemoteAddr = "127.0.0.1:40001"
	response = httptest.NewRecorder()
	service.dashboardAPI().ServeHTTP(response, request)
	if response.Code != http.StatusForbidden {
		t.Fatalf("unexpected dashboard host accepted: %d", response.Code)
	}
	for _, path := range []string{"/", "/style.css", "/app.js"} {
		response = localRequest(service, path)
		if response.Code != http.StatusOK {
			t.Errorf("dashboard asset %s returned %d", path, response.Code)
		}
	}
}

func TestConcurrentDuplicateUploads(t *testing.T) {
	service := testRelay(t, t.TempDir())
	const calls = 4
	results := make(chan int, calls)
	for range calls {
		go func() {
			response := sendCapture(service, "same-capture", "屏幕录制.mp4", "screen-recording", []byte("test video"))
			results <- response.Code
		}()
	}
	created := 0
	for range calls {
		switch code := <-results; code {
		case http.StatusCreated:
			created++
		case http.StatusOK:
		default:
			t.Errorf("retry returned %d", code)
		}
	}
	if created != 1 || len(service.locations.recent(40)) != 1 {
		t.Fatalf("expected one committed capture, got %d", created)
	}
}

type readTimeout struct{}

func (readTimeout) Read([]byte) (int, error) { return 0, os.ErrDeadlineExceeded }

type uploadDeadlineRecorder struct {
	*httptest.ResponseRecorder
	receivedDeadline time.Time
}

func (r *uploadDeadlineRecorder) SetReadDeadline(value time.Time) error {
	r.receivedDeadline = value
	return nil
}

func TestStalledUploadCanRetryWithSameID(t *testing.T) {
	service := testRelay(t, t.TempDir())
	request := httptest.NewRequest(http.MethodPost, "/api/v1/uploads", nil)
	request.Body = io.NopCloser(io.MultiReader(strings.NewReader("part"), readTimeout{}))
	request.ContentLength = 8
	request.Header.Set("Authorization", "Bearer "+service.token)
	request.Header.Set("X-Filename", "fresh.mp4")
	request.Header.Set("X-Media-Kind", "screen-recording")
	request.Header.Set("X-Upload-Id", "stalled-capture")
	response := &uploadDeadlineRecorder{ResponseRecorder: httptest.NewRecorder()}
	service.phoneAPI().ServeHTTP(response, request)

	if response.Code != http.StatusServiceUnavailable || response.Header().Get("Retry-After") != "5" {
		t.Fatalf("stalled upload was not retryable: %d %s", response.Code, response.Body)
	}
	if delay := time.Until(response.receivedDeadline); delay < uploadIdleTime-time.Second || delay > uploadIdleTime {
		t.Fatalf("unbounded or incorrect upload idle deadline: %s", delay)
	}
	files, err := os.ReadDir(service.locations.current().state)
	if err != nil || len(files) != 0 {
		t.Fatalf("timed out upload left data behind: %v %v", files, err)
	}

	retry := sendCapture(service, "stalled-capture", "fresh.mp4", "screen-recording", []byte("complete"))
	if retry.Code != http.StatusCreated || len(service.locations.recent(40)) != 1 {
		t.Fatalf("could not commit the retried upload: %d %s", retry.Code, retry.Body)
	}
}

func changeFolderFromDashboard(s *relay, path, origin string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"path": path})
	request := httptest.NewRequest(http.MethodPost, "http://"+s.dashboardHost+"/api/folder", bytes.NewReader(body))
	request.RemoteAddr = "127.0.0.1:40001"
	request.Header.Set("X-ScreenRelay", "1")
	request.Header.Set("Origin", origin)
	response := httptest.NewRecorder()
	s.dashboardAPI().ServeHTTP(response, request)
	return response
}

func TestDashboardCanChangeFolderWithoutLosingReceivedFiles(t *testing.T) {
	parent := t.TempDir()
	initial := filepath.Join(parent, "first")
	next := filepath.Join(parent, "新保存目录")
	service := testRelay(t, initial)

	origin := "http://" + service.dashboardHost
	if got := changeFolderFromDashboard(service, next, "https://other.example"); got.Code != http.StatusForbidden {
		t.Fatalf("cross-origin save location request got %d", got.Code)
	}
	if got := changeFolderFromDashboard(service, "relative/new", origin); got.Code != http.StatusBadRequest {
		t.Fatalf("relative dashboard save location got %d", got.Code)
	}
	ordinaryFile := filepath.Join(parent, "not-a-directory")
	if err := os.WriteFile(ordinaryFile, []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if got := changeFolderFromDashboard(service, ordinaryFile, origin); got.Code != http.StatusBadRequest {
		t.Fatalf("save location pointing to a file got %d", got.Code)
	}
	if service.locations.current().root != initial {
		t.Fatal("rejected directory replaced the active folder")
	}

	content := []byte("screenshot saved before the change")
	old := sendCapture(service, "old-device.capture", "原截图.png", "screenshot", content)
	if old.Code != http.StatusCreated {
		t.Fatalf("first upload: %d %s", old.Code, old.Body)
	}
	var oldReceipt struct {
		ID string `json:"id"`
	}
	if err := json.Unmarshal(old.Body.Bytes(), &oldReceipt); err != nil {
		t.Fatal(err)
	}

	changed := changeFolderFromDashboard(service, next, origin)
	var selected map[string]string
	if err := json.Unmarshal(changed.Body.Bytes(), &selected); err != nil ||
		changed.Code != http.StatusOK || selected["folder"] != next {
		t.Fatalf("save location change failed: %d %s", changed.Code, changed.Body)
	}
	if retry := sendCapture(service, "old-device.capture", "原截图.png", "screenshot", content); retry.Code != http.StatusOK {
		t.Fatalf("existing upload retried after the change got %d", retry.Code)
	}
	if fresh := sendCapture(service, "new-device.capture", "新录屏.mp4", "screen-recording", []byte("video")); fresh.Code != http.StatusCreated {
		t.Fatalf("new upload: %d %s", fresh.Code, fresh.Body)
	}
	if files := service.locations.current().recent(40); len(files) != 1 || files[0].Name != "新录屏.mp4" {
		t.Fatalf("wrong files in new directory: %+v", files)
	}

	service = testRelay(t, initial)
	response := localRequest(service, "/api/status")
	var status dashboardStatus
	if err := json.Unmarshal(response.Body.Bytes(), &status); err != nil ||
		status.Folder != next || len(status.Recent) != 2 {
		t.Fatalf("saved location or received-file list did not survive restart: %s", response.Body)
	}
	oldFile := localRequest(service, "/files/"+oldReceipt.ID+"?download=1")
	if oldFile.Code != http.StatusOK || !bytes.Equal(oldFile.Body.Bytes(), content) {
		t.Fatalf("previous download link was lost after switching folders: %d", oldFile.Code)
	}
}
