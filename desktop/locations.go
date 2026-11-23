package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
)

type receiveLocationSettings struct {
	Current string   `json:"current,omitempty"`
	Photo   string   `json:"photo,omitempty"`
	Folders []string `json:"folders"`
}

func (s *receiveLocationSettings) remember(folder string) {
	if folder != "" && !slices.Contains(s.Folders, folder) {
		s.Folders = append(slices.Clone(s.Folders), folder)
	}
}

type photoDestination struct {
	PhotoFolder       string `json:"photoFolder"`
	PhotoFolderCustom bool   `json:"photoFolderCustom"`
}

type uploadLocation struct {
	store *captureStore
	ready chan struct{}
	users int
}

type receiveLocations struct {
	settingsPath string
	changeMu     sync.Mutex
	settings     receiveLocationSettings

	mu          sync.RWMutex
	stores      []*captureStore // The current store is first. Published slices are immutable.
	photoFolder string
	photoStore  *captureStore
	active      map[string]*uploadLocation
}

func loadReceiveLocations(settingsPath, defaultFolder, explicitFolder string) (*receiveLocations, error) {
	var settings receiveLocationSettings
	data, err := os.ReadFile(settingsPath)
	if err == nil {
		if err := json.Unmarshal(data, &settings); err != nil {
			return nil, fmt.Errorf("read receive folder settings: %w", err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return nil, err
	}

	selectedFolder := defaultFolder
	if settings.Current != "" {
		selectedFolder = settings.Current
	}
	if explicitFolder != "" {
		selectedFolder = explicitFolder
	}
	folder, err := absoluteReceiveFolder(selectedFolder)
	if err != nil {
		return nil, err
	}
	selected, err := loadWritableReceiveStore(folder)
	if err != nil {
		return nil, err
	}
	var photoFolder string
	if settings.Photo != "" {
		photoFolder, err = absoluteReceiveFolder(settings.Photo)
		if err != nil {
			return nil, err
		}
	}

	locations := &receiveLocations{
		settingsPath: settingsPath,
		settings:     settings,
		stores:       []*captureStore{selected},
		photoFolder:  photoFolder,
		active:       make(map[string]*uploadLocation),
	}
	paths := append(slices.Clone(settings.Folders), settings.Current, defaultFolder, photoFolder)
	seen := map[string]bool{folder: true}
	for _, path := range paths {
		if !filepath.IsAbs(path) {
			continue
		}
		path = filepath.Clean(path)
		if seen[path] {
			continue
		}
		seen[path] = true
		if store, err := readStore(path); err == nil {
			locations.stores = append(locations.stores, store)
		}
	}
	locations.photoStore = storeAt(locations.stores, photoFolder)
	previousCount := len(settings.Folders)
	settings.remember(folder)
	settings.remember(photoFolder)
	if len(settings.Folders) != previousCount {
		if err := locations.persist(settings); err != nil {
			return nil, err
		}
	}
	return locations, nil
}

func absoluteReceiveFolder(folder string) (string, error) {
	if strings.TrimSpace(folder) == "" {
		return "", errors.New("receive folder is required")
	}
	return filepath.Abs(folder)
}

func loadWritableReceiveStore(folder string) (*captureStore, error) {
	store, err := loadStore(folder)
	if err != nil {
		return nil, err
	}
	if err := checkReceiveStoreWritable(store); err != nil {
		return nil, err
	}
	return store, nil
}

func checkReceiveStoreWritable(store *captureStore) error {
	for _, dir := range []string{store.root, store.state} {
		file, err := os.CreateTemp(dir, ".screenrelay-check-*")
		if err != nil {
			return err
		}
		if err := errors.Join(file.Close(), os.Remove(file.Name())); err != nil {
			return err
		}
	}
	return nil
}

func (l *receiveLocations) persist(settings receiveLocationSettings) error {
	data, err := json.Marshal(settings)
	if err != nil {
		return err
	}
	if err := writeAtomic(l.settingsPath, data, false); err != nil {
		return fmt.Errorf("save receive folder settings: %w", err)
	}
	l.settings = settings
	return nil
}

func (l *receiveLocations) current() *captureStore {
	l.mu.RLock()
	defer l.mu.RUnlock()
	return l.stores[0]
}

func (l *receiveLocations) folders() (string, photoDestination) {
	l.mu.RLock()
	defer l.mu.RUnlock()
	current := l.stores[0].root
	if l.photoFolder != "" {
		return current, photoDestination{PhotoFolder: l.photoFolder, PhotoFolderCustom: true}
	}
	return current, photoDestination{PhotoFolder: current}
}

func (l *receiveLocations) change(folder string) (string, error) {
	folder, err := absoluteReceiveFolder(folder)
	if err != nil {
		return "", err
	}
	l.changeMu.Lock()
	defer l.changeMu.Unlock()

	stores := l.stores
	selected, err := writableStoreAt(stores, folder)
	if err != nil {
		return "", err
	}

	settings := l.settings
	settings.Current = folder
	settings.remember(folder)
	if err := l.persist(settings); err != nil {
		return "", err
	}

	next := make([]*captureStore, 0, len(stores)+1)
	next = append(next, selected)
	for _, store := range stores {
		if store != selected {
			next = append(next, store)
		}
	}
	l.mu.Lock()
	l.stores = next
	if l.photoFolder == folder {
		l.photoStore = selected
	}
	l.mu.Unlock()
	return folder, nil
}

func (l *receiveLocations) changePhoto(folder string) (photoDestination, error) {
	l.changeMu.Lock()
	defer l.changeMu.Unlock()

	stores := l.stores
	var selected *captureStore
	if folder != "" {
		var err error
		folder, err = absoluteReceiveFolder(folder)
		if err != nil {
			return photoDestination{}, err
		}
		selected, err = writableStoreAt(stores, folder)
		if err != nil {
			return photoDestination{}, err
		}
		if !slices.Contains(stores, selected) {
			stores = append(slices.Clone(stores), selected)
		}
	}
	settings := l.settings
	settings.Photo = folder
	settings.remember(folder)
	if err := l.persist(settings); err != nil {
		return photoDestination{}, err
	}
	l.mu.Lock()
	l.stores = stores
	l.photoFolder = folder
	l.photoStore = selected
	l.mu.Unlock()
	_, destination := l.folders()
	return destination, nil
}

func storeAt(stores []*captureStore, folder string) *captureStore {
	for _, store := range stores {
		if store.root == folder {
			return store
		}
	}
	return nil
}

func writableStoreAt(stores []*captureStore, folder string) (*captureStore, error) {
	if store := storeAt(stores, folder); store != nil {
		return store, checkReceiveStoreWritable(store)
	}
	return loadWritableReceiveStore(folder)
}

func (l *receiveLocations) reopenPhotoStore() {
	l.mu.RLock()
	offline := l.photoFolder != "" && l.photoStore == nil
	l.mu.RUnlock()
	if !offline {
		return
	}

	// A mounted folder may become available again after startup. Reopen it
	// without creating anything at the previously unavailable path.
	l.changeMu.Lock()
	defer l.changeMu.Unlock()
	if l.photoFolder == "" || l.photoStore != nil {
		return
	}
	store, err := readStore(l.photoFolder)
	if err != nil {
		return
	}
	l.mu.Lock()
	l.stores = append(slices.Clone(l.stores), store)
	l.photoStore = store
	l.mu.Unlock()
}

// Called with mu held.
func (l *receiveLocations) storeForKind(kind string) *captureStore {
	if kind == photoKind && l.photoFolder != "" {
		return l.photoStore
	}
	return l.stores[0]
}

func captureIDForUpload(uploadID string) string {
	if uploadID == "" {
		return ""
	}
	hash := sha256.Sum256([]byte(uploadID))
	return hex.EncodeToString(hash[:])
}

func (l *receiveLocations) openUpload(uploadID, kind string) (*captureStore, func()) {
	if kind == photoKind {
		l.reopenPhotoStore()
	}
	id := captureIDForUpload(uploadID)
	if id == "" {
		l.mu.RLock()
		defer l.mu.RUnlock()
		return l.storeForKind(kind), func() {}
	}

	l.mu.Lock()
	entry := l.active[id]
	if entry == nil {
		// Reserve the ID before checking the disk so concurrent requests share one
		// destination, even if the current folder changes during the lookup.
		entry = &uploadLocation{store: l.storeForKind(kind), ready: make(chan struct{}), users: 1}
		l.active[id] = entry
		stores := l.stores
		l.mu.Unlock()
		if _, previous, ok := findCaptureStore(stores, id); ok {
			entry.store = previous
		}
		close(entry.ready)
	} else {
		entry.users++
		l.mu.Unlock()
		<-entry.ready
	}
	return entry.store, func() {
		l.mu.Lock()
		defer l.mu.Unlock()
		entry.users--
		if entry.users == 0 {
			delete(l.active, id)
		}
	}
}

func (l *receiveLocations) recent(limit int) []capture {
	l.mu.RLock()
	stores := l.stores
	l.mu.RUnlock()

	records := make([]capture, 0)
	seen := make(map[string]bool)
	if limit <= 0 {
		return records
	}
	for _, store := range stores {
		for _, record := range store.recent(limit) {
			if !seen[record.ID] {
				records = append(records, record)
				seen[record.ID] = true
			}
		}
	}
	slices.SortFunc(records, func(a, b capture) int {
		if order := b.ReceivedAt.Compare(a.ReceivedAt); order != 0 {
			return order
		}
		return strings.Compare(a.ID, b.ID)
	})
	return records[:min(limit, len(records))]
}

func (l *receiveLocations) find(id string) (capture, *captureStore, bool) {
	l.mu.RLock()
	stores := l.stores
	l.mu.RUnlock()
	return findCaptureStore(stores, id)
}

func findCaptureStore(stores []*captureStore, id string) (capture, *captureStore, bool) {
	for _, store := range stores {
		if record, ok := store.get(id); ok && existingFile(record, store.root) {
			return record, store, true
		}
	}
	return capture{}, nil, false
}
