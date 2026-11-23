package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"image/png"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func requestPairingQR(s *relay, address, origin string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(map[string]string{"address": address})
	request := httptest.NewRequest(http.MethodPost, "http://"+s.dashboardHost+"/api/pairing", bytes.NewReader(body))
	request.RemoteAddr = "127.0.0.1:40001"
	request.Header.Set("X-ScreenRelay", "1")
	request.Header.Set("Origin", origin)
	response := httptest.NewRecorder()
	s.dashboardAPI().ServeHTTP(response, request)
	return response
}

func requestPairing(s *relay, code, id, name string) *httptest.ResponseRecorder {
	body, _ := json.Marshal(devicePairing{Code: code, DeviceID: id, DeviceName: name})
	request := httptest.NewRequest(http.MethodPost, "/api/v1/pair", bytes.NewReader(body))
	request.Header.Set("Content-Type", "application/json")
	response := httptest.NewRecorder()
	s.phoneAPI().ServeHTTP(response, request)
	return response
}

func readDeviceToken(t *testing.T, response *httptest.ResponseRecorder, status int) string {
	t.Helper()
	if response.Code != status {
		t.Fatalf("pair status %d; wanted %d: %s", response.Code, status, response.Body)
	}
	var result struct {
		Token string `json:"token"`
	}
	if err := json.Unmarshal(response.Body.Bytes(), &result); err != nil || len(result.Token) != 43 {
		t.Fatalf("invalid device token response: %v", err)
	}
	return result.Token
}

func uploadWithDeviceToken(s *relay, token, uploadID string) *httptest.ResponseRecorder {
	request := httptest.NewRequest(http.MethodPost, "/api/v1/uploads", strings.NewReader("image data"))
	request.Header.Set("Authorization", "Bearer "+token)
	request.Header.Set("X-Media-Kind", "screenshot")
	request.Header.Set("X-Filename", "Screenshot.png")
	request.Header.Set("X-Upload-Id", uploadID)
	response := httptest.NewRecorder()
	s.phoneAPI().ServeHTTP(response, request)
	return response
}

func TestQRPairingMultipleDevicesAndRestart(t *testing.T) {
	folder := t.TempDir()
	service := testRelay(t, folder)

	address := "http://192.168.0.1:8765"
	origin := "http://" + service.dashboardHost
	qr := requestPairingQR(service, address, origin)
	if qr.Code != http.StatusOK {
		t.Fatalf("could not create QR code: %d %s", qr.Code, qr.Body)
	}
	var invitation struct {
		Image     string    `json:"image"`
		ExpiresAt time.Time `json:"expiresAt"`
	}
	if err := json.Unmarshal(qr.Body.Bytes(), &invitation); err != nil {
		t.Fatal(err)
	}
	pngData, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(invitation.Image, "data:image/png;base64,"))
	if err != nil {
		t.Fatal(err)
	}
	if config, err := png.DecodeConfig(bytes.NewReader(pngData)); err != nil || config.Width != 320 || config.Height != 320 {
		t.Fatalf("invalid QR image: %+v %v", config, err)
	}
	code, expiry := service.pairings.invite(time.Now())
	if !expiry.Equal(invitation.ExpiresAt) {
		t.Fatal("the displayed QR and active pairing invitation must expire together")
	}

	first, second := make(chan *httptest.ResponseRecorder, 1), make(chan *httptest.ResponseRecorder, 1)
	go func() { first <- requestPairing(service, code, "phone-one", "Android 测试机") }()
	go func() { second <- requestPairing(service, code, "phone-two", "iPhone") }()
	firstToken := readDeviceToken(t, <-first, http.StatusCreated)
	secondToken := readDeviceToken(t, <-second, http.StatusCreated)
	if firstToken == secondToken || firstToken == service.token || secondToken == service.token {
		t.Fatal("phones must have independent credentials")
	}
	retry := requestPairing(service, code, "phone-one", "Android 测试机")
	if readDeviceToken(t, retry, http.StatusOK) != firstToken {
		t.Fatal("a retry must return the same device token")
	}

	service = testRelay(t, folder)
	status := localRequest(service, "/api/status")
	var info dashboardStatus
	err = json.Unmarshal(status.Body.Bytes(), &info)
	if err != nil || len(info.Devices) != 2 || info.Token != service.token {
		t.Fatalf("dashboard did not restore both paired devices: %v", err)
	}
	if strings.Contains(status.Body.String(), firstToken) || strings.Contains(status.Body.String(), secondToken) {
		t.Fatal("dashboard status exposed device credentials")
	}
	for id, token := range map[string]string{"phone-one.capture": firstToken, "phone-two.capture": secondToken, "legacy.capture": service.token} {
		if upload := uploadWithDeviceToken(service, token, id); upload.Code != http.StatusCreated {
			t.Fatalf("device capture %s rejected: %d %s", id, upload.Code, upload.Body)
		}
	}
}

func TestPairingInvitationIsolationAndExpiry(t *testing.T) {
	service := testRelay(t, t.TempDir())
	address := "http://192.168.0.1:8765"
	origin := "http://" + service.dashboardHost
	if got := requestPairingQR(service, address, "https://other.example"); got.Code != http.StatusForbidden {
		t.Fatalf("cross-origin pairing QR request got %d", got.Code)
	}
	if got := requestPairingQR(service, "https://other.example", origin); got.Code != http.StatusBadRequest {
		t.Fatalf("unadvertised pairing address got %d", got.Code)
	}
	stale, _ := service.pairings.invite(time.Now().Add(-pairingDuration - time.Second))
	if got := requestPairing(service, stale, "new-phone", "Android"); got.Code != http.StatusUnauthorized {
		t.Fatalf("expired invitation got %d", got.Code)
	}

	valid, _ := service.pairings.invite(time.Now())
	if got := requestPairing(service, valid, "invalid/id", "Android"); got.Code != http.StatusBadRequest {
		t.Fatalf("invalid device ID got %d", got.Code)
	}
	for token, label := range map[string]string{stale: "expired code", valid: "active invitation"} {
		if got := uploadWithDeviceToken(service, token, "upload"); got.Code != http.StatusUnauthorized {
			t.Fatalf("%s authorized an upload: %d", label, got.Code)
		}
	}
}

func TestConcurrentPairingNormalizesUUIDOnly(t *testing.T) {
	folder := t.TempDir()
	service := testRelay(t, folder)
	const lowercase = "051f4cf8-2080-4c52-88c1-904196c500f9"
	uppercase := strings.ToUpper(lowercase)
	code, _ := service.pairings.invite(time.Now())
	results := make(chan *httptest.ResponseRecorder, 6)
	for _, id := range []string{lowercase, uppercase, lowercase, uppercase, lowercase, uppercase} {
		go func() { results <- requestPairing(service, code, id, "iPhone") }()
	}
	var token string
	created := 0
	for range cap(results) {
		response := <-results
		if response.Code == http.StatusCreated {
			created++
		} else if response.Code != http.StatusOK {
			t.Fatalf("repeat scan got %d: %s", response.Code, response.Body)
		}
		received := readDeviceToken(t, response, response.Code)
		if token != "" && token != received {
			t.Fatal("repeat scan changed the token")
		}
		token = received
	}
	if created != 1 {
		t.Fatalf("got %d new pairings for one phone", created)
	}
	for _, id := range []string{"phone-one", "PHONE-ONE"} {
		other := readDeviceToken(t, requestPairing(service, code, id, "iPhone"), http.StatusCreated)
		if other == token {
			t.Fatal("distinct device with the same name shares a token")
		}
	}

	service = testRelay(t, folder)
	devices := service.pairings.summaries()
	if len(devices) != 3 || devices[0].ID != lowercase {
		t.Fatalf("unexpected device list after restart: %+v", devices)
	}
	code, _ = service.pairings.invite(time.Now())
	if got := readDeviceToken(t, requestPairing(service, code, uppercase, "iPhone"), http.StatusOK); got != token {
		t.Fatal("same device lost its token after restart")
	}
}

func TestRemoveConsolidatedPairedDevice(t *testing.T) {
	folder := t.TempDir()
	path := filepath.Join(folder, "paired-devices.json")
	const id = "32689ffc-7607-4f04-8fe0-6a418c3a2892"
	const otherID = "921a9712-934e-44ff-8fbc-ace3fd41c55a"
	oldest, old, newest, other := newPairingSecret(), newPairingSecret(), newPairingSecret(), newPairingSecret()
	now := time.Now().UTC()
	data, _ := json.Marshal([]pairedDevice{
		{pairedDeviceSummary: pairedDeviceSummary{ID: id, Name: "iPhone", PairedAt: now}, Token: newest},
		{pairedDeviceSummary: pairedDeviceSummary{ID: strings.ToUpper(id), Name: "iPhone", PairedAt: now.Add(-time.Hour)}, Token: oldest},
		{pairedDeviceSummary: pairedDeviceSummary{ID: id, Name: "iPhone", PairedAt: now.Add(-time.Minute)}, Token: old},
		{pairedDeviceSummary: pairedDeviceSummary{ID: otherID, Name: "iPhone", PairedAt: now}, Token: other},
	})
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	service := testRelay(t, folder)
	if devices := service.pairings.summaries(); len(devices) != 2 || devices[0].ID != id {
		t.Fatalf("legacy entries did not normalize: %+v", devices)
	}
	code, _ := service.pairings.invite(time.Now())
	updated := requestPairing(service, code, id, "我的 iPhone")
	if token := readDeviceToken(t, updated, http.StatusOK); token != oldest {
		t.Fatal("repeat scan did not reuse the original token")
	}
	service = testRelay(t, folder)
	for _, token := range []string{oldest, old, newest, other} {
		if !service.pairings.accepts(token) {
			t.Fatal("valid prior token was lost during registry migration")
		}
	}

	const route = "/api/paired-devices/remove"
	origin := "http://" + service.dashboardHost
	body, _ := json.Marshal(map[string]string{"id": strings.ToUpper(id)})
	if denied := postFromDashboard(service, route, "https://other.example", body); denied.Code != http.StatusForbidden {
		t.Fatalf("cross-origin remove got %d", denied.Code)
	}
	if invalid := postFromDashboard(service, route, origin, []byte(`{"id":"not/an/id"}`)); invalid.Code != http.StatusBadRequest {
		t.Fatalf("invalid removal ID got %d", invalid.Code)
	}
	remote := httptest.NewRecorder()
	service.phoneAPI().ServeHTTP(remote, httptest.NewRequest(http.MethodPost, route, bytes.NewReader(body)))
	if remote.Code != http.StatusNotFound {
		t.Fatalf("phone listener exposed removal: %d", remote.Code)
	}

	service.pairings.path = filepath.Join(folder, "missing", "paired-devices.json")
	if failed := postFromDashboard(service, route, origin, body); failed.Code != http.StatusInternalServerError ||
		!service.pairings.accepts(oldest) || len(service.pairings.summaries()) != 2 {
		t.Fatalf("unpersisted removal did not preserve device: %d", failed.Code)
	}
	service.pairings.path = path
	for range 2 {
		if removed := postFromDashboard(service, route, origin, body); removed.Code != http.StatusNoContent {
			t.Fatalf("removal request got %d: %s", removed.Code, removed.Body)
		}
	}
	service = testRelay(t, folder)
	if devices := service.pairings.summaries(); len(devices) != 1 || devices[0].ID != otherID {
		t.Fatalf("wrong entries removed: %+v", devices)
	}
	for _, token := range []string{oldest, old, newest} {
		if upload := uploadWithDeviceToken(service, token, "removed-device"); upload.Code != http.StatusUnauthorized {
			t.Fatalf("removed device can still upload: %d", upload.Code)
		}
	}
	if upload := uploadWithDeviceToken(service, other, "other-device"); upload.Code != http.StatusCreated {
		t.Fatalf("unrelated device lost its token: %d", upload.Code)
	}
}
