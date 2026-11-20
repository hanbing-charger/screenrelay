package main

import (
	"bytes"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func testRelay(t *testing.T, folder string) *relay {
	t.Helper()
	store, err := loadStore(folder)
	if err != nil {
		t.Fatal(err)
	}
	return &relay{
		store: store, token: "test-pairing-token", maxBytes: 1024,
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

	records := service.store.recent(40)
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
	entries, err := os.ReadDir(filepath.Join(service.store.root, stateDirectory))
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
	if created != 1 || len(service.store.recent(40)) != 1 {
		t.Fatalf("expected one committed capture, got %d", created)
	}
}
