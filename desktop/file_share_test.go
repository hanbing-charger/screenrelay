package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func requestFileShare(s *relay, path, address, origin string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"path": path, "address": address})
	request := httptest.NewRequest(http.MethodPost, "http://"+s.dashboardHost+"/api/file-share", bytes.NewReader(body))
	request.RemoteAddr = "127.0.0.1:40001"
	request.Header.Set("Origin", origin)
	request.Header.Set("X-ScreenRelay", "1")
	response := httptest.NewRecorder()
	s.dashboardAPI().ServeHTTP(response, request)
	return response
}

func requestSharedDownload(s *relay, method, token, rangeHeader, ifRange string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(method, "/api/v1/download", nil)
	if token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}
	request.Header.Set("Range", rangeHeader)
	request.Header.Set("If-Range", ifRange)
	response := httptest.NewRecorder()
	s.phoneAPI().ServeHTTP(response, request)
	return response
}

func TestFileShareDownloadsCanResume(t *testing.T) {
	folder := t.TempDir()
	receiver := testRelay(t, folder)
	name := "资料 + 版本.zip"
	path := filepath.Join(folder, name)
	contents := []byte("A complete file selected on the desktop")
	if err := os.WriteFile(path, contents, 0o600); err != nil {
		t.Fatal(err)
	}
	request := requestFileShare(receiver, path, "http://192.168.0.1:8765", "http://"+receiver.dashboardHost)
	var generated struct {
		Name      string    `json:"name"`
		Size      int       `json:"size"`
		Image     string    `json:"image"`
		ExpiresAt time.Time `json:"expiresAt"`
	}
	if err := json.Unmarshal(request.Body.Bytes(), &generated); err != nil ||
		request.Code != http.StatusOK || generated.Name != name || generated.Size != len(contents) ||
		!generated.ExpiresAt.After(time.Now()) {
		t.Fatalf("bad share response: %d (%v)", request.Code, err)
	}
	prefix, encoded, hasPrefix := strings.Cut(generated.Image, ",")
	if _, err := base64.StdEncoding.DecodeString(encoded); err != nil || !hasPrefix || prefix != "data:image/png;base64" {
		t.Fatal("file share response did not contain a PNG QR")
	}

	var code string
	for key := range receiver.shares.byCode {
		code = key
	}
	if code == "" {
		t.Fatal("no download code was issued")
	}
	head := requestSharedDownload(receiver, http.MethodHead, code, "", "")
	etag := head.Header().Get("ETag")
	filename, _ := url.PathUnescape(head.Header().Get("X-Filename"))
	if head.Code != http.StatusOK || filename != name || etag == "" ||
		head.Header().Get("Content-Length") != strconv.Itoa(len(contents)) || head.Body.Len() != 0 ||
		head.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("unexpected HEAD response: %d %+v", head.Code, head.Header())
	}
	first := requestSharedDownload(receiver, http.MethodGet, code, "bytes=0-5", etag)
	second := requestSharedDownload(receiver, http.MethodGet, code, "bytes=6-", etag)
	if first.Code != http.StatusPartialContent || second.Code != http.StatusPartialContent ||
		second.Header().Get("Content-Range") != "bytes 6-"+strconv.Itoa(len(contents)-1)+"/"+strconv.Itoa(len(contents)) ||
		second.Header().Get("ETag") != etag ||
		!bytes.Equal(append(first.Body.Bytes(), second.Body.Bytes()...), contents) {
		t.Fatal("ranged response did not resume the same file")
	}
	badRange := requestSharedDownload(receiver, http.MethodGet, code, "bytes=9999-", etag)
	if badRange.Code != http.StatusRequestedRangeNotSatisfiable {
		t.Fatalf("bad range got %d", badRange.Code)
	}
	changedETag := requestSharedDownload(receiver, http.MethodGet, code, "bytes=6-", `"other"`)
	if changedETag.Code != http.StatusOK || !bytes.Equal(changedETag.Body.Bytes(), contents) {
		t.Fatal("mismatched If-Range did not return the complete file")
	}
	if unauth := requestSharedDownload(receiver, http.MethodGet, "", "", ""); unauth.Code != http.StatusUnauthorized {
		t.Fatalf("anonymous read got %d", unauth.Code)
	}
	if upload := uploadWithDeviceToken(receiver, code, "not-permitted"); upload.Code != http.StatusUnauthorized {
		t.Fatalf("download code authorized upload: %d", upload.Code)
	}
}

func TestFileShareRejectsInvalidSourceAndExpiredCode(t *testing.T) {
	folder := t.TempDir()
	receiver := testRelay(t, folder)
	path := filepath.Join(folder, "empty")
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	address := "http://192.168.0.1:8765"
	origin := "http://" + receiver.dashboardHost
	for _, check := range []struct {
		path, address, origin string
		status                int
	}{
		{path, address, "https://other.example", http.StatusForbidden},
		{path, "http://different.example", origin, http.StatusBadRequest},
		{folder, address, origin, http.StatusBadRequest},
		{"relative.zip", address, origin, http.StatusBadRequest},
	} {
		if response := requestFileShare(receiver, check.path, check.address, check.origin); response.Code != check.status {
			t.Fatalf("invalid share creation got %d, want %d", response.Code, check.status)
		}
	}

	create := func() string {
		t.Helper()
		receiver.shares.byCode = nil
		if result := requestFileShare(receiver, path, address, origin); result.Code != http.StatusOK {
			t.Fatalf("empty file share got %d", result.Code)
		}
		for code := range receiver.shares.byCode {
			return code
		}
		t.Fatal("no share code")
		return ""
	}
	code := create()
	if zero := requestSharedDownload(receiver, http.MethodGet, code, "", ""); zero.Code != http.StatusOK || zero.Body.Len() != 0 {
		t.Fatalf("empty file GET got %d with %d bytes", zero.Code, zero.Body.Len())
	}
	if _, ok := receiver.shares.find(code, time.Now().Add(fileShareDuration)); ok {
		t.Fatal("expired share remained valid")
	}
	if expired := requestSharedDownload(receiver, http.MethodGet, code, "", ""); expired.Code != http.StatusGone {
		t.Fatalf("expired share got %d", expired.Code)
	}

	code = create()
	if err := os.WriteFile(path, []byte("different content"), 0o600); err != nil {
		t.Fatal(err)
	}
	if changed := requestSharedDownload(receiver, http.MethodGet, code, "", ""); changed.Code != http.StatusGone {
		t.Fatalf("modified file got %d", changed.Code)
	}
}
