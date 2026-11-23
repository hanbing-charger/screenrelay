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
	"regexp"
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
var uuidDeviceID = regexp.MustCompile(`(?i)^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$`)

type pairedDeviceSummary struct {
	ID       string    `json:"id"`
	Name     string    `json:"name"`
	PairedAt time.Time `json:"pairedAt"`
}

type pairedDevice struct {
	pairedDeviceSummary
	Token        string   `json:"token"`
	LegacyTokens []string `json:"legacyTokens,omitempty"`
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

func canonicalDeviceID(id string) string {
	if uuidDeviceID.MatchString(id) {
		return strings.ToLower(id)
	}
	return id
}

func validDeviceToken(token string) bool {
	rawToken, err := base64.RawURLEncoding.DecodeString(token)
	return err == nil && len(rawToken) == 32
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
		if !uploadIDPattern.MatchString(device.ID) || !validDeviceToken(device.Token) ||
			device.PairedAt.IsZero() || device.Name == "" {
			return nil, errors.New("invalid paired device record")
		}
		for _, token := range device.LegacyTokens {
			if !validDeviceToken(token) {
				return nil, errors.New("invalid paired device record")
			}
		}
		device.ID = canonicalDeviceID(device.ID)
		if previous, exists := registry.devices[device.ID]; exists {
			device = mergePairedDevices(previous, device)
		}
		registry.devices[device.ID] = device
	}
	return registry, nil
}

func mergePairedDevices(first, second pairedDevice) pairedDevice {
	if second.PairedAt.Before(first.PairedAt) {
		first, second = second, first
	}
	for _, token := range append([]string{second.Token}, second.LegacyTokens...) {
		if token != first.Token && !slices.Contains(first.LegacyTokens, token) {
			first.LegacyTokens = append(first.LegacyTokens, token)
		}
	}
	return first
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

	id := canonicalDeviceID(request.DeviceID)
	device, exists := p.devices[id]
	if exists && device.Name == request.DeviceName {
		return device, false, nil
	}
	if !exists {
		device = pairedDevice{
			pairedDeviceSummary: pairedDeviceSummary{ID: id, PairedAt: now.UTC()},
			Token:               newPairingSecret(),
		}
	}
	device.Name = request.DeviceName
	next := maps.Clone(p.devices)
	next[device.ID] = device
	if err := p.persist(next); err != nil {
		return pairedDevice{}, false, err
	}
	return device, !exists, nil
}

func (p *pairingRegistry) remove(id string) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	id = canonicalDeviceID(id)
	if _, exists := p.devices[id]; !exists {
		return nil
	}
	next := maps.Clone(p.devices)
	delete(next, id)
	return p.persist(next)
}

// Called with mu held.
func (p *pairingRegistry) persist(next map[string]pairedDevice) error {
	devices := slices.AppendSeq(make([]pairedDevice, 0, len(next)), maps.Values(next))
	data, err := json.Marshal(devices)
	if err != nil {
		return err
	}
	if err := writeAtomic(p.path, data, false); err != nil {
		return err
	}
	p.devices = next
	return nil
}

func (p *pairingRegistry) accepts(token string) bool {
	p.mu.RLock()
	defer p.mu.RUnlock()
	for _, device := range p.devices {
		if subtle.ConstantTimeCompare([]byte(token), []byte(device.Token)) == 1 {
			return true
		}
		for _, previous := range device.LegacyTokens {
			if subtle.ConstantTimeCompare([]byte(token), []byte(previous)) == 1 {
				return true
			}
		}
	}
	return false
}

func (s *relay) removePairedDevice(w http.ResponseWriter, r *http.Request) {
	if !s.dashboardActionAllowed(r) {
		writeError(w, http.StatusForbidden, "dashboard origin required")
		return
	}
	var request struct {
		ID string `json:"id"`
	}
	if err := readSmallJSON(w, r, &request); err != nil || !uploadIDPattern.MatchString(request.ID) {
		writeError(w, http.StatusBadRequest, "invalid device identifier")
		return
	}
	if err := s.pairings.remove(request.ID); err != nil {
		log.Printf("移除配对设备失败 %v", err)
		writeError(w, http.StatusInternalServerError, "无法移除配对设备")
		return
	}
	w.WriteHeader(http.StatusNoContent)
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
	image, err := transferQRCode("pair", request.Address, code)
	if err != nil {
		log.Printf("生成配对二维码失败 %v", err)
		writeError(w, http.StatusInternalServerError, "无法生成二维码")
		return
	}
	writeJSON(w, http.StatusOK, struct {
		Image     string    `json:"image"`
		ExpiresAt time.Time `json:"expiresAt"`
	}{
		Image:     image,
		ExpiresAt: deadline.UTC(),
	})
}

func transferQRCode(action, address, code string) (string, error) {
	query := make(url.Values)
	query.Set("v", "1")
	query.Set("url", address)
	query.Set("code", code)
	payload := url.URL{Scheme: "screenrelay", Host: action, RawQuery: query.Encode()}
	png, err := qrcode.Encode(payload.String(), qrcode.Medium, 320)
	if err != nil {
		return "", err
	}
	return "data:image/png;base64," + base64.StdEncoding.EncodeToString(png), nil
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
