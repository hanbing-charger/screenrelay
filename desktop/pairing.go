package main

import (
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"log"
	"maps"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"

	"github.com/skip2/go-qrcode"
)

const pairingDuration = 10 * time.Minute

var errInvalidInvitation = errors.New("invalid or expired pairing code")

type pairedDeviceSummary struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	PairedAt time.Time `json:"pairedAt"`
}

type pairedDevice struct {
	pairedDeviceSummary
	Token string `json:"token"`
}

type devicePairing struct {
	Code       string `json:"pairingCode"`
	DeviceID   string `json:"deviceId"`
	DeviceName string `json:"deviceName"`
}

type pairingRegistry struct {
	mu       sync.RWMutex
	path     string
	devices  map[string]pairedDevice
	code     string
	deadline time.Time
}

func newPairingSecret() string {
	return base64.RawURLEncoding.EncodeToString(randBytes(32))
}

func loadPairings(path string) (*pairingRegistry, error) {
	registry := &pairingRegistry{path: path, devices: make(map[string]pairedDevice)}
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return registry, nil
	}
	if err != nil {
		return nil, err
	}
	var stored []pairedDevice
	if err := json.Unmarshal(data, &stored); err != nil {
		return nil, err
	}
	for _, device := range stored {
		rawToken, decodeErr := base64.RawURLEncoding.DecodeString(device.Token)
		if !uploadIDPattern.MatchString(device.ID) || decodeErr != nil || len(rawToken) != 32 ||
			device.PairedAt.IsZero() || device.Name == "" {
			return nil, errors.New("invalid paired device record")
		}
		if _, exists := registry.devices[device.ID]; exists {
			return nil, errors.New("duplicate paired device identifier")
		}
		registry.devices[device.ID] = device
	}
	return registry, nil
}

func (p *pairingRegistry) invite(now time.Time) (string, time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !now.Before(p.deadline) {
		p.code = newPairingSecret()
		p.deadline = now.Add(pairingDuration)
	}
	return p.code, p.deadline
}

func (p *pairingRegistry) pair(request devicePairing, now time.Time) (pairedDevice, bool, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if !now.Before(p.deadline) ||
		subtle.ConstantTimeCompare([]byte(request.Code), []byte(p.code)) != 1 {
		return pairedDevice{}, false, errInvalidInvitation
	}

	device, exists := p.devices[request.DeviceID]
	if exists && device.Name == request.DeviceName {
		return device, false, nil
	}
	if !exists {
		device = pairedDevice{
			pairedDeviceSummary: pairedDeviceSummary{ID: request.DeviceID, PairedAt: now.UTC()},
			Token:               newPairingSecret(),
		}
	}
	device.Name = request.DeviceName
	next := maps.Clone(p.devices)
	next[device.ID] = device
	data, err := json.Marshal(slices.Collect(maps.Values(next)))
	if err != nil {
		return pairedDevice{}, false, err
	}
	if err := writeAtomic(p.path, data, false); err != nil {
		return pairedDevice{}, false, err
	}
	p.devices = next
	return device, !exists, nil
}

func (p *pairingRegistry) accepts(token string) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	for _, device := range p.devices {
		if subtle.ConstantTimeCompare([]byte(token), []byte(device.Token)) == 1 {
			return true
		}
	}
	return false
}

func (p *pairingRegistry) summaries() []pairedDeviceSummary {
	p.mu.RLock()
	defer p.mu.RUnlock()
	devices := make([]pairedDeviceSummary, 0, len(p.devices))
	for _, device := range p.devices {
		devices = append(devices, device.pairedDeviceSummary)
	}
	slices.SortFunc(devices, func(a, b pairedDeviceSummary) int {
		if order := a.PairedAt.Compare(b.PairedAt); order != 0 {
			return order
		}
		return strings.Compare(a.ID, b.ID)
	})
	return devices
}

func readSmallJSON(w http.ResponseWriter, r *http.Request, target any) error {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4096))
	if err != nil {
		return err
	}
	return json.Unmarshal(body, target)
}

func (s *relay) showPairingQR(w http.ResponseWriter, r *http.Request) {
	if !s.dashboardActionAllowed(r) {
		writeError(w, http.StatusForbidden, "dashboard origin required")
		return
	}
	var request struct {
		Address string `json:"address"`
	}
	if err := readSmallJSON(w, r, &request); err != nil ||
		!slices.Contains(advertiseAddresses(s.listening, s.scheme), request.Address) {
		writeError(w, http.StatusBadRequest, "请选择有效的局域网接收地址")
		return
	}

	code, deadline := s.pairings.invite(time.Now())
	query := make(url.Values)
	query.Set("v", "1")
	query.Set("url", request.Address)
	query.Set("code", code)
	payload := url.URL{Scheme: "screenrelay", Host: "pair", RawQuery: query.Encode()}
	png, err := qrcode.Encode(payload.String(), qrcode.Medium, 320)
	if err != nil {
		log.Printf("生成配对二维码失败 %v", err)
		writeError(w, http.StatusInternalServerError, "无法生成二维码")
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Image     string    `json:"image"`
		ExpiresAt time.Time `json:"expiresAt"`
	}{
		Image:     "data:image/png;base64," + base64.StdEncoding.EncodeToString(png),
		ExpiresAt: deadline.UTC(),
	})
}

func (s *relay) pairDevice(w http.ResponseWriter, r *http.Request) {
	// Pairing requests have small bodies and need not use the upload timeout.
	http.NewResponseController(w).SetReadDeadline(time.Now().Add(8 * time.Second))
	var request devicePairing
	if err := readSmallJSON(w, r, &request); err != nil {
		writeError(w, http.StatusBadRequest, "invalid pairing request")
		return
	}
	request.DeviceName = strings.TrimSpace(request.DeviceName)
	if request.DeviceName == "" {
		request.DeviceName = "手机"
	}
	if !uploadIDPattern.MatchString(request.DeviceID) || utf8.RuneCountInString(request.DeviceName) > 80 ||
		strings.IndexFunc(request.DeviceName, unicode.IsControl) >= 0 {
		writeError(w, http.StatusBadRequest, "invalid device identifier or name")
		return
	}

	device, created, err := s.pairings.pair(request, time.Now())
	switch {
	case errors.Is(err, errInvalidInvitation):
		writeError(w, http.StatusUnauthorized, err.Error())
	case err != nil:
		log.Printf("保存配对设备失败 %v", err)
		writeError(w, http.StatusInternalServerError, "failed to save paired device")
	default:
		status := http.StatusOK
		if created {
			status = http.StatusCreated
		}
		writeJSON(w, status, map[string]string{"token": device.Token})
	}
}
