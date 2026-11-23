package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestReceiveLocationChangesKeepActiveUploadsAndHistory(t *testing.T) {
	base := t.TempDir()
	settings := filepath.Join(base, "receive-folders.json")
	firstFolder := filepath.Join(base, "first")
	secondFolder := filepath.Join(base, "second")
	locations, err := loadReceiveLocations(settings, firstFolder, "")
	if err != nil {
		t.Fatal(err)
	}
	first, releaseFirst := locations.openUpload("active", "screenshot")
	if first.root != firstFolder {
		t.Fatalf("initial upload destination = %q, want %q", first.root, firstFolder)
	}
	if folder, err := locations.change(secondFolder); err != nil || folder != secondFolder {
		t.Fatalf("change folder = %q, %v", folder, err)
	}

	duplicateReady := make(chan *captureStore)
	duplicateDone := make(chan struct{})
	go func() {
		duplicate, releaseDuplicate := locations.openUpload("active", "screenshot")
		duplicateReady <- duplicate
		releaseDuplicate()
		close(duplicateDone)
	}()
	if duplicate := <-duplicateReady; duplicate != first {
		t.Errorf("in-flight retry destination = %q, want %q", duplicate.root, firstFolder)
	}
	<-duplicateDone

	firstRecord, created, err := first.save(strings.NewReader("one"), 3, "active", "first.png", "screenshot")
	releaseFirst()
	if err != nil || !created {
		t.Fatalf("save active upload: created=%v, err=%v", created, err)
	}
	second, releaseSecond := locations.openUpload("new", "screenshot")
	secondRecord, created, err := second.save(strings.NewReader("two"), 3, "new", "second.png", "screenshot")
	releaseSecond()
	if err != nil || !created || second.root != secondFolder {
		t.Fatalf("save new upload in %q: created=%v, err=%v", second.root, created, err)
	}
	if record, store, ok := locations.find(firstRecord.ID); !ok || record != firstRecord || store != first {
		t.Fatal("previous folder capture cannot be found")
	}
	if records := locations.recent(2); len(records) != 2 || records[0] != secondRecord || records[1] != firstRecord {
		t.Fatalf("combined history = %+v", records)
	}

	restarted, err := loadReceiveLocations(settings, firstFolder, "")
	if err != nil {
		t.Fatal(err)
	}
	if restarted.current().root != secondFolder {
		t.Fatalf("restored current folder = %q, want %q", restarted.current().root, secondFolder)
	}
	retry, releaseRetry := restarted.openUpload("active", "screenshot")
	repeated, created, err := retry.save(strings.NewReader("one"), 3, "active", "first.png", "screenshot")
	releaseRetry()
	if err != nil || created || repeated != firstRecord || retry.root != firstFolder {
		t.Fatalf("retry after restart in %q: capture=%+v, created=%v, err=%v", retry.root, repeated, created, err)
	}
}

func TestReceiveLocationStartupOverrideAndMissingHistory(t *testing.T) {
	base := t.TempDir()
	settings := filepath.Join(base, "receive-folders.json")
	defaultFolder := filepath.Join(base, "default")
	chosen := filepath.Join(base, "dashboard")
	explicit := filepath.Join(base, "explicit")
	locations, err := loadReceiveLocations(settings, defaultFolder, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := locations.change(chosen); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(base, "file")
	if err := os.WriteFile(file, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := locations.change(file); err == nil || locations.current().root != chosen {
		t.Fatalf("invalid switch returned %v and selected %q", err, locations.current().root)
	}

	overridden, err := loadReceiveLocations(settings, defaultFolder, explicit)
	if err != nil {
		t.Fatal(err)
	}
	if overridden.current().root != explicit {
		t.Fatalf("explicit startup destination = %q, want %q", overridden.current().root, explicit)
	}
	if err := os.Rename(defaultFolder, filepath.Join(base, "offline")); err != nil {
		t.Fatal(err)
	}

	restarted, err := loadReceiveLocations(settings, defaultFolder, "")
	if err != nil {
		t.Fatal(err)
	}
	if restarted.current().root != chosen {
		t.Fatalf("restored current folder = %q, want %q", restarted.current().root, chosen)
	}
	if _, err := os.Stat(defaultFolder); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("missing historical folder was re-created or unavailable for another reason: %v", err)
	}
}

func TestPhotoLocationPinsActiveUploadsAndReopensAfterRemount(t *testing.T) {
	base := t.TempDir()
	settings := filepath.Join(base, "receive-folders.json")
	defaultFolder := filepath.Join(base, "default")
	photoFolder := filepath.Join(base, "photos")
	locations, err := loadReceiveLocations(settings, defaultFolder, "")
	if err != nil {
		t.Fatal(err)
	}
	first, releaseFirst := locations.openUpload("active-photo", photoKind)
	if _, err := locations.changePhoto(photoFolder); err != nil {
		t.Fatal(err)
	}
	duplicate, releaseDuplicate := locations.openUpload("active-photo", photoKind)
	if first != duplicate || first.root != defaultFolder {
		t.Fatal("photo override redirected an existing reservation")
	}
	releaseDuplicate()
	releaseFirst()

	offlineFolder := filepath.Join(base, "offline")
	if err := os.Rename(photoFolder, offlineFolder); err != nil {
		t.Fatal(err)
	}
	locations, err = loadReceiveLocations(settings, defaultFolder, "")
	if err != nil {
		t.Fatal(err)
	}
	if _, status := locations.folders(); !status.PhotoFolderCustom || status.PhotoFolder != photoFolder {
		t.Fatalf("offline folder was not preserved: %+v", status)
	}
	photo, releasePhoto := locations.openUpload("new-photo", photoKind)
	releasePhoto()
	if photo != nil {
		t.Fatal("photo should wait for configured destination")
	}
	if _, err := os.Stat(photoFolder); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("offline folder was re-created or unavailable for another reason: %v", err)
	}
	capture, releaseCapture := locations.openUpload("new-screenshot", "screenshot")
	releaseCapture()
	if capture.root != defaultFolder {
		t.Fatal("offline photo folder interrupted screenshot routing")
	}
	if err := os.Rename(offlineFolder, photoFolder); err != nil {
		t.Fatal(err)
	}
	photo, releasePhoto = locations.openUpload("new-photo", photoKind)
	releasePhoto()
	if photo == nil || photo.root != photoFolder {
		t.Fatal("photo folder did not recover after being remounted")
	}
}
