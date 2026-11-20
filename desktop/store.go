package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"
	"unicode"
	"unicode/utf8"
)

const (
	stateDirectory   = ".screenrelay"
	uploadBufferSize = 256 * 1024
)

var uploadBuffers = sync.Pool{New: func() any { return new([uploadBufferSize]byte) }}

var errIDConflict = errors.New("upload ID already belongs to a different file")
var errIncomplete = errors.New("body length did not match Content-Length")
var errUploadTimeout = errors.New("upload stopped receiving data")

type capture struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Kind       string    `json:"kind"`
	Size       int64     `json:"size"`
	ReceivedAt time.Time `json:"receivedAt"`
	ContentSHA string    `json:"sha256"`
}

func (c capture) path(root string) string {
	return filepath.Join(root, c.ReceivedAt.Format(time.DateOnly), c.Kind,
		c.ID[:16]+"-"+c.Name)
}

type captureStore struct {
	root    string
	state   string
	mu      sync.RWMutex
	records map[string]capture
}

func loadStore(folder string) (*captureStore, error) {
	root, err := filepath.Abs(folder)
	if err != nil {
		return nil, err
	}
	store := &captureStore{
		root: root, state: filepath.Join(root, stateDirectory),
		records: make(map[string]capture),
	}
	if err := os.MkdirAll(store.state, 0o700); err != nil {
		return nil, err
	}
	files, err := os.ReadDir(store.state)
	if err != nil {
		return nil, err
	}
	for _, file := range files {
		if filepath.Ext(file.Name()) != ".json" || !file.Type().IsRegular() {
			continue
		}
		text, err := os.ReadFile(filepath.Join(store.state, file.Name()))
		if err != nil {
			return nil, err
		}
		var record capture
		if json.Unmarshal(text, &record) != nil || !validHexID(record.ID) ||
			file.Name() != record.ID+".json" ||
			record.Name == "" || record.Name != sanitizeName(record.Name) ||
			record.ReceivedAt.IsZero() || !validKind(record.Kind) {
			continue
		}
		if existingFile(record, root) {
			store.records[record.ID] = record
		}
	}
	return store, nil
}

func validHexID(id string) bool {
	if len(id) != 64 {
		return false
	}
	_, err := hex.DecodeString(id)
	return err == nil
}

func existingFile(record capture, root string) bool {
	info, err := os.Lstat(record.path(root))
	return err == nil && info.Mode().IsRegular() && info.Size() == record.Size
}

func (s *captureStore) save(body io.Reader, length int64, uploadID, name, kind string) (capture, bool, error) {
	id := hex.EncodeToString(randBytes(32))
	if uploadID != "" {
		encoded := sha256.Sum256([]byte(uploadID))
		id = hex.EncodeToString(encoded[:])
	}

	file, err := os.CreateTemp(s.state, "incoming-*")
	if err != nil {
		return capture{}, false, err
	}
	defer os.Remove(file.Name())
	hash := sha256.New()
	buffer := uploadBuffers.Get().(*[uploadBufferSize]byte)
	written, copyErr := io.CopyBuffer(io.MultiWriter(file, hash), body, buffer[:])
	uploadBuffers.Put(buffer)
	if copyErr != nil || written != length {
		file.Close()
		var timeout interface{ Timeout() bool }
		if errors.As(copyErr, &timeout) && timeout.Timeout() {
			return capture{}, false, errUploadTimeout
		}
		var pathErr *os.PathError
		if errors.As(copyErr, &pathErr) {
			return capture{}, false, copyErr
		}
		return capture{}, false, errIncomplete
	}
	err = file.Sync()
	closeErr := file.Close()
	if err = errors.Join(err, closeErr); err != nil {
		return capture{}, false, err
	}

	record := capture{
		ID: id, Name: name, Kind: kind, Size: written, ReceivedAt: time.Now().UTC(),
		ContentSHA: hex.EncodeToString(hash.Sum(nil)),
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if prior, ok := s.records[id]; ok && existingFile(prior, s.root) {
		if prior.Size != record.Size || prior.ContentSHA != record.ContentSHA ||
			prior.Name != record.Name || prior.Kind != record.Kind {
			return capture{}, false, errIDConflict
		}
		return prior, false, nil
	}

	destination := record.path(s.root)
	if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
		return capture{}, false, err
	}
	metadata, err := json.Marshal(record)
	if err != nil {
		return capture{}, false, err
	}
	// Publish metadata first. On startup an entry is visible only if its complete
	// file also exists, so interruption at either rename remains retryable.
	if err := writeAtomic(filepath.Join(s.state, id+".json"), metadata, false); err != nil {
		return capture{}, false, err
	}
	if err := os.Rename(file.Name(), destination); err != nil {
		return capture{}, false, err
	}
	syncDirectory(filepath.Dir(destination))
	s.records[id] = record
	return record, true, nil
}

func (s *captureStore) get(id string) (capture, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	record, exists := s.records[id]
	return record, exists
}

func (s *captureStore) recent(limit int) []capture {
	s.mu.RLock()
	defer s.mu.RUnlock()
	records := make([]capture, 0, len(s.records))
	for _, record := range s.records {
		records = append(records, record)
	}
	slices.SortFunc(records, func(a, b capture) int { return b.ReceivedAt.Compare(a.ReceivedAt) })
	recent := make([]capture, 0, min(limit, len(records)))
	for _, record := range records {
		if existingFile(record, s.root) {
			recent = append(recent, record)
			if len(recent) == limit {
				break
			}
		}
	}
	return recent
}

func writeNewFile(destination string, contents []byte) error {
	return writeAtomic(destination, contents, true)
}

func writeAtomic(destination string, contents []byte, exclusive bool) error {
	dir := filepath.Dir(destination)
	file, err := os.CreateTemp(dir, ".write-*")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	_, err = file.Write(contents)
	if err == nil {
		err = file.Sync()
	}
	if err = errors.Join(err, file.Close()); err != nil {
		return err
	}
	if exclusive {
		err = os.Link(file.Name(), destination)
	} else {
		err = os.Rename(file.Name(), destination)
	}
	if err != nil {
		return fmt.Errorf("commit %s: %w", filepath.Base(destination), err)
	}
	syncDirectory(dir)
	return nil
}

func syncDirectory(dir string) {
	if file, err := os.Open(dir); err == nil {
		file.Sync()
		file.Close()
	}
}

func sanitizeName(name string) string {
	if !utf8.ValidString(name) {
		return ""
	}
	name = strings.Map(func(ch rune) rune {
		if unicode.IsControl(ch) || unicode.Is(unicode.Cf, ch) || strings.ContainsRune(`<>:"/\|?*`, ch) {
			return '_'
		}
		return ch
	}, name)
	name = strings.Trim(name, " .")
	const maxFilename = 175
	if len(name) <= maxFilename {
		return name
	}
	ext := filepath.Ext(name)
	if len(ext) > 12 {
		return ""
	}
	stem := strings.TrimSuffix(name, ext)
	for len(stem) > maxFilename-len(ext) {
		_, length := utf8.DecodeLastRuneInString(stem)
		stem = stem[:len(stem)-length]
	}
	return stem + ext
}
