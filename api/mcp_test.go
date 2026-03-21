package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// --- OpenReadOnlyDB tests (Task 2) ---

func TestOpenReadOnlyDB(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	store.Close()

	roDB, err := OpenReadOnlyDB(dir)
	if err != nil {
		t.Fatalf("OpenReadOnlyDB: %v", err)
	}
	defer roDB.Close()

	var count int
	err = roDB.QueryRow("SELECT COUNT(*) FROM events").Scan(&count)
	if err != nil {
		t.Fatalf("read query failed: %v", err)
	}

	_, err = roDB.Exec("INSERT INTO events (id, app_id, event, timestamp) VALUES ('test', 'test', 'test', '2024-01-01T00:00:00Z')")
	if err == nil {
		t.Fatal("expected write to fail on read-only DB, but it succeeded")
	}
}

func TestOpenReadOnlyDB_MissingFile(t *testing.T) {
	dir := t.TempDir()
	_, err := OpenReadOnlyDB(dir)
	if err == nil {
		t.Fatal("expected error when DB file doesn't exist")
	}
}

// --- Query validation tests (Task 3) ---

func TestValidateQuery(t *testing.T) {
	tests := []struct {
		name    string
		sql     string
		wantErr bool
	}{
		{"simple select", "SELECT * FROM events", false},
		{"select with where", "SELECT id FROM events WHERE app_id = 'murmur-ios'", false},
		{"select with json_extract", "SELECT json_extract(properties, '$.cost_micros') FROM events", false},
		{"CTE select", "WITH recent AS (SELECT * FROM events ORDER BY timestamp DESC LIMIT 10) SELECT * FROM recent", false},
		{"leading whitespace", "  SELECT 1", false},
		{"case insensitive", "select * from events", false},
		{"with lowercase", "with cte as (select 1) select * from cte", false},

		{"empty", "", true},
		{"insert", "INSERT INTO events VALUES ('a','b','c','d')", true},
		{"delete", "DELETE FROM events", true},
		{"drop", "DROP TABLE events", true},
		{"update", "UPDATE events SET app_id = 'x'", true},
		{"alter", "ALTER TABLE events ADD COLUMN foo TEXT", true},
		{"attach", "ATTACH DATABASE 'other.db' AS other", true},
		{"detach", "DETACH DATABASE other", true},
		{"pragma", "PRAGMA table_info(events)", true},
		{"semicolon multi-statement", "SELECT 1; DROP TABLE events", true},
		{"CTE with delete", "WITH x AS (SELECT 1) DELETE FROM events", true},
		{"CTE with insert", "WITH x AS (SELECT 1) INSERT INTO events VALUES ('a','b','c','d')", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := validateQuery(tt.sql)
			if tt.wantErr && err == nil {
				t.Errorf("expected error for %q, got nil", tt.sql)
			}
			if !tt.wantErr && err != nil {
				t.Errorf("unexpected error for %q: %v", tt.sql, err)
			}
		})
	}
}

// --- SQL executor tests (Task 4) ---

func setupTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dir := t.TempDir()

	store, err := OpenStore(dir)
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	_, err = store.InsertEvents([]Event{
		{ID: "evt-1", AppID: "murmur-ios", EventName: "llm.request", Timestamp: "2024-01-15T10:00:00Z", Properties: `{"cost_micros": 500, "tokens_in": 100}`, Context: `{"device_id": "d1"}`},
		{ID: "evt-2", AppID: "murmur-ios", EventName: "llm.request", Timestamp: "2024-01-15T11:00:00Z", Properties: `{"cost_micros": 300, "tokens_in": 50}`, Context: `{"device_id": "d2"}`},
		{ID: "evt-3", AppID: "murmur-ios", EventName: "entry.created", Timestamp: "2024-01-15T12:00:00Z", Properties: `{}`, Context: `{"device_id": "d1"}`},
	})
	if err != nil {
		t.Fatalf("InsertEvents: %v", err)
	}
	store.Close()

	roDB, err := OpenReadOnlyDB(dir)
	if err != nil {
		t.Fatalf("OpenReadOnlyDB: %v", err)
	}
	t.Cleanup(func() { roDB.Close() })
	return roDB
}

func TestExecuteQuery(t *testing.T) {
	db := setupTestDB(t)
	ctx := context.Background()

	t.Run("basic select", func(t *testing.T) {
		result, err := executeQuery(ctx, db, "SELECT id, event FROM events ORDER BY timestamp")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		var rows []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &rows); err != nil {
			t.Fatalf("invalid JSON: %v", err)
		}
		if len(rows) != 3 {
			t.Fatalf("expected 3 rows, got %d", len(rows))
		}
		if rows[0]["id"] != "evt-1" {
			t.Errorf("expected first row id=evt-1, got %v", rows[0]["id"])
		}
	})

	t.Run("json_extract", func(t *testing.T) {
		result, err := executeQuery(ctx, db, "SELECT json_extract(properties, '$.cost_micros') as cost FROM events WHERE event = 'llm.request' ORDER BY timestamp")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		var rows []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &rows); err != nil {
			t.Fatalf("invalid JSON: %v", err)
		}
		if len(rows) != 2 {
			t.Fatalf("expected 2 rows, got %d", len(rows))
		}
	})

	t.Run("aggregate", func(t *testing.T) {
		result, err := executeQuery(ctx, db, "SELECT COUNT(*) as cnt FROM events")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}

		var rows []map[string]interface{}
		if err := json.Unmarshal([]byte(result), &rows); err != nil {
			t.Fatalf("invalid JSON: %v", err)
		}
		if len(rows) != 1 {
			t.Fatalf("expected 1 row, got %d", len(rows))
		}
	})

	t.Run("empty result", func(t *testing.T) {
		result, err := executeQuery(ctx, db, "SELECT * FROM events WHERE app_id = 'nonexistent'")
		if err != nil {
			t.Fatalf("unexpected error: %v", err)
		}
		if result != "[]" {
			t.Errorf("expected empty array, got %s", result)
		}
	})

	t.Run("bad sql", func(t *testing.T) {
		_, err := executeQuery(ctx, db, "SELECT * FROM nonexistent_table")
		if err == nil {
			t.Fatal("expected error for bad table")
		}
	})

	t.Run("timeout", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(ctx, 1*time.Nanosecond)
		defer cancel()
		time.Sleep(1 * time.Millisecond)
		_, err := executeQuery(ctx, db, "SELECT * FROM events")
		if err == nil {
			t.Fatal("expected timeout error")
		}
	})
}

func TestExecuteQuery_RowLimit(t *testing.T) {
	dir := t.TempDir()
	store, err := OpenStore(dir)
	if err != nil {
		t.Fatalf("OpenStore: %v", err)
	}
	events := make([]Event, 1005)
	for i := range events {
		events[i] = Event{
			ID:         fmt.Sprintf("evt-%d", i),
			AppID:      "test",
			EventName:  "test.event",
			Timestamp:  "2024-01-15T10:00:00Z",
			Properties: "{}",
			Context:    "{}",
		}
	}
	_, err = store.InsertEvents(events)
	if err != nil {
		t.Fatalf("InsertEvents: %v", err)
	}
	store.Close()

	roDB, err := OpenReadOnlyDB(dir)
	if err != nil {
		t.Fatalf("OpenReadOnlyDB: %v", err)
	}
	defer roDB.Close()

	result, err := executeQuery(context.Background(), roDB, "SELECT * FROM events")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !strings.Contains(result, "[Warning: results truncated") {
		t.Error("expected truncation warning in result")
	}

	jsonPart := strings.SplitN(result, "\n\n[Warning", 2)[0]
	var rows []map[string]interface{}
	if err := json.Unmarshal([]byte(jsonPart), &rows); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if len(rows) != maxRows {
		t.Errorf("expected %d rows (capped), got %d", maxRows, len(rows))
	}
}

// --- MCP handler tests (Task 5) ---

func TestMCPHandler_AuthReject(t *testing.T) {
	db := setupTestDB(t)
	keys := map[string]string{"testkey": "test-app"}
	authMW := APIKeyAuth(keys)
	handler := authMW(newMCPHandler(db))

	req := httptest.NewRequest("POST", "/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusUnauthorized {
		t.Errorf("expected 401, got %d", w.Code)
	}
}

func TestMCPHandler_Initialize(t *testing.T) {
	db := setupTestDB(t)
	handler := newMCPHandler(db)

	req := httptest.NewRequest("POST", "/mcp", strings.NewReader(`{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}`))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json, text/event-stream")
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)

	if w.Code != http.StatusOK {
		body, _ := io.ReadAll(w.Body)
		t.Fatalf("expected 200, got %d: %s", w.Code, body)
	}

	body, _ := io.ReadAll(w.Body)
	if !strings.Contains(string(body), "damsac-studio") {
		t.Errorf("expected server name in response, got: %s", body)
	}
}
