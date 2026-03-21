package main

import (
	"testing"
)

func TestOpenReadOnlyDB(t *testing.T) {
	// Create a temp dir with a real database via OpenStore (which runs migrations).
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	store.Close()

	// Now open read-only.
	roDB, err := OpenReadOnlyDB(dir)
	if err != nil {
		t.Fatalf("OpenReadOnlyDB: %v", err)
	}
	defer roDB.Close()

	// Should be able to read.
	var count int
	err = roDB.QueryRow("SELECT COUNT(*) FROM events").Scan(&count)
	if err != nil {
		t.Fatalf("read query failed: %v", err)
	}

	// Should reject writes.
	_, err = roDB.Exec("INSERT INTO events (id, app_id, event, timestamp) VALUES ('test', 'test', 'test', '2024-01-01T00:00:00Z')")
	if err == nil {
		t.Fatal("expected write to fail on read-only DB, but it succeeded")
	}
}

func TestOpenReadOnlyDB_MissingFile(t *testing.T) {
	dir := t.TempDir()
	// No database file exists — should fail.
	_, err := OpenReadOnlyDB(dir)
	if err == nil {
		t.Fatal("expected error when DB file doesn't exist")
	}
}
