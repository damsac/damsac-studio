# MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an MCP Streamable HTTP endpoint to damsac-studio with a single read-only SQL `query` tool.

**Architecture:** Embed MCP server in the existing Go binary. Mount `/mcp` on the existing mux behind API key auth. Read-only SQLite connection opened with `file:` URI format. Uses `github.com/modelcontextprotocol/go-sdk` v1.4.1 for protocol handling.

**Tech Stack:** Go 1.25, `github.com/modelcontextprotocol/go-sdk/mcp`, `modernc.org/sqlite`, stdlib `net/http`

**Spec:** `docs/superpowers/specs/2026-03-21-mcp-server-design.md`

---

## File Structure

| File | Responsibility |
|------|---------------|
| `api/mcp.go` (create) | MCP server factory, `query` tool registration + handler, SQL validation + execution |
| `api/mcp_test.go` (create) | Tests for query validation, SQL execution, and MCP tool handler |
| `api/store.go` (modify) | Add `OpenReadOnlyDB(dataDir)` returning `*sql.DB` |
| `api/main.go` (modify) | Open read-only DB, create MCP handler, mount `/mcp` route |
| `api/go.mod` (modify) | Add `github.com/modelcontextprotocol/go-sdk` dependency |

---

### Task 1: Add Go MCP SDK dependency

**Files:**
- Modify: `api/go.mod`
- Modify: `api/go.sum`

- [ ] **Step 1: Add the SDK dependency**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go get github.com/modelcontextprotocol/go-sdk@v1.4.1
```

- [ ] **Step 2: Tidy modules**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go mod tidy
```

- [ ] **Step 3: Verify go directive bumped to 1.25+**

The SDK requires Go 1.25. Check that `go mod tidy` bumped the directive:

```bash
head -3 /Users/claude/damsac-studio/api/go.mod
```

Expected: `go 1.25` (or higher). If still `go 1.24.0`, manually edit `api/go.mod` line 3 to `go 1.25`.

- [ ] **Step 4: Verify build still works**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go build ./...
```

Expected: clean build, no errors.

- [ ] **Step 5: Commit**

```bash
cd /Users/claude/damsac-studio && git add api/go.mod api/go.sum
git commit -m "deps: add Go MCP SDK v1.4.1"
```

---

### Task 2: Add OpenReadOnlyDB to store.go

**Files:**
- Modify: `api/store.go`
- Create: `api/mcp_test.go`

- [ ] **Step 1: Write the failing test for OpenReadOnlyDB**

In `api/mcp_test.go`:

```go
package main

import (
	"os"
	"path/filepath"
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run TestOpenReadOnlyDB -v ./...
```

Expected: compilation error — `OpenReadOnlyDB` undefined.

- [ ] **Step 3: Implement OpenReadOnlyDB in store.go**

Add at the end of `api/store.go`:

```go
// OpenReadOnlyDB opens a read-only connection to the SQLite database.
// Must be called after OpenStore (which creates the file and runs migrations).
// Returns a raw *sql.DB — not a Store — since no writes are possible.
func OpenReadOnlyDB(dataDir string) (*sql.DB, error) {
	dbPath := filepath.Join(dataDir, "studio.db")

	// Verify the file exists before opening (mode=ro won't create it,
	// but we want a clear error message).
	if _, err := os.Stat(dbPath); err != nil {
		return nil, fmt.Errorf("read-only db: %w", err)
	}

	// file: URI format is required for modernc.org/sqlite to honor query params.
	// _pragma params are applied per-connection, so the pool can have >1 conn.
	dsn := fmt.Sprintf("file:%s?mode=ro&_pragma=busy_timeout(5000)", dbPath)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, fmt.Errorf("open read-only db: %w", err)
	}

	if err := db.Ping(); err != nil {
		db.Close()
		return nil, fmt.Errorf("ping read-only db: %w", err)
	}

	return db, nil
}
```

Add `"os"` to the imports in store.go (it's not currently imported).

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run TestOpenReadOnlyDB -v ./...
```

Expected: both tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/claude/damsac-studio && git add api/store.go api/mcp_test.go
git commit -m "feat: add read-only SQLite connection factory for MCP"
```

---

### Task 3: Add query validation

**Files:**
- Create: `api/mcp.go`
- Modify: `api/mcp_test.go`

- [ ] **Step 1: Write the failing tests for validateQuery**

Append to `api/mcp_test.go`:

```go
func TestValidateQuery(t *testing.T) {
	tests := []struct {
		name    string
		sql     string
		wantErr bool
	}{
		// Valid queries
		{"simple select", "SELECT * FROM events", false},
		{"select with where", "SELECT id FROM events WHERE app_id = 'murmur-ios'", false},
		{"select with json_extract", "SELECT json_extract(properties, '$.cost_micros') FROM events", false},
		{"CTE select", "WITH recent AS (SELECT * FROM events ORDER BY timestamp DESC LIMIT 10) SELECT * FROM recent", false},
		{"leading whitespace", "  SELECT 1", false},
		{"case insensitive", "select * from events", false},
		{"with lowercase", "with cte as (select 1) select * from cte", false},

		// Invalid queries
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run TestValidateQuery -v ./...
```

Expected: compilation error — `validateQuery` undefined.

- [ ] **Step 3: Implement validateQuery in mcp.go**

Create `api/mcp.go`:

```go
package main

import (
	"fmt"
	"strings"
)

// validateQuery checks that a SQL string is a safe read-only query.
// This is defense-in-depth — the read-only SQLite connection is the primary safety net.
func validateQuery(sql string) error {
	trimmed := strings.TrimSpace(sql)
	if trimmed == "" {
		return fmt.Errorf("empty query")
	}

	// Reject semicolons — prevents multi-statement attacks.
	// Strip trailing semicolons first (common in hand-written SQL).
	cleaned := strings.TrimRight(trimmed, "; \t\n")
	if strings.Contains(cleaned, ";") {
		return fmt.Errorf("multiple statements not allowed")
	}

	upper := strings.ToUpper(cleaned)

	// Must start with SELECT or WITH.
	if !strings.HasPrefix(upper, "SELECT") && !strings.HasPrefix(upper, "WITH") {
		return fmt.Errorf("only SELECT queries are allowed")
	}

	// For WITH (CTE) queries, find the final statement after all CTEs.
	// CTEs look like: WITH name AS (...) [, name AS (...)]* SELECT ...
	// We need to verify the final clause is a SELECT.
	if strings.HasPrefix(upper, "WITH") {
		// Find the last unparenthesized SELECT/INSERT/UPDATE/DELETE.
		finalKeyword := findFinalStatement(upper)
		if finalKeyword != "SELECT" {
			return fmt.Errorf("CTE must end with SELECT, got %s", finalKeyword)
		}
	}

	// Block dangerous keywords anywhere in the query.
	blocked := []string{"INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "ATTACH", "DETACH", "PRAGMA"}
	// Skip this check for WITH queries that already passed the CTE check.
	if !strings.HasPrefix(upper, "WITH") {
		for _, kw := range blocked {
			if containsKeyword(upper, kw) {
				return fmt.Errorf("blocked keyword: %s", kw)
			}
		}
	}

	return nil
}

// findFinalStatement finds the keyword that starts the final (non-CTE) statement.
// It tracks parenthesis depth to skip over CTE bodies.
func findFinalStatement(upper string) string {
	depth := 0
	keywords := []string{"SELECT", "INSERT", "UPDATE", "DELETE"}
	lastFound := ""

	i := 0
	for i < len(upper) {
		if upper[i] == '(' {
			depth++
			i++
			continue
		}
		if upper[i] == ')' {
			depth--
			i++
			continue
		}
		if depth == 0 {
			for _, kw := range keywords {
				if i+len(kw) <= len(upper) && upper[i:i+len(kw)] == kw {
					// Check word boundary.
					if i+len(kw) == len(upper) || !isIdentChar(upper[i+len(kw)]) {
						lastFound = kw
					}
				}
			}
		}
		i++
	}

	return lastFound
}

// isIdentChar returns true if c can be part of a SQL identifier.
func isIdentChar(c byte) bool {
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
}

// containsKeyword checks if a SQL keyword appears as a whole word in the query.
func containsKeyword(upper, keyword string) bool {
	start := 0
	for {
		idx := strings.Index(upper[start:], keyword)
		if idx == -1 {
			return false
		}
		pos := start + idx
		// Check word boundaries.
		before := pos == 0 || !isIdentChar(upper[pos-1])
		after := pos+len(keyword) == len(upper) || !isIdentChar(upper[pos+len(keyword)])
		if before && after {
			return true
		}
		start = pos + 1
	}
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run TestValidateQuery -v ./...
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/claude/damsac-studio && git add api/mcp.go api/mcp_test.go
git commit -m "feat: add SQL query validation for MCP read-only tool"
```

---

### Task 4: Add SQL query executor

**Files:**
- Modify: `api/mcp.go`
- Modify: `api/mcp_test.go`

- [ ] **Step 1: Write the failing tests for executeQuery**

Append to `api/mcp_test.go`:

```go
import (
	"context"
	"encoding/json"
	"time"
)

func setupTestDB(t *testing.T) *sql.DB {
	t.Helper()
	dir := t.TempDir()

	// Create and seed the database.
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
		time.Sleep(1 * time.Millisecond) // ensure context is expired
		_, err := executeQuery(ctx, db, "SELECT * FROM events")
		if err == nil {
			t.Fatal("expected timeout error")
		}
	})
}

func TestExecuteQuery_RowLimit(t *testing.T) {
	// Create a DB with more than maxRows events.
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

	// Result should contain truncation warning.
	if !strings.Contains(result, "[Warning: results truncated") {
		t.Error("expected truncation warning in result")
	}

	// Extract the JSON part (before the warning).
	jsonPart := strings.SplitN(result, "\n\n[Warning", 2)[0]
	var rows []map[string]interface{}
	if err := json.Unmarshal([]byte(jsonPart), &rows); err != nil {
		t.Fatalf("invalid JSON: %v", err)
	}
	if len(rows) != maxRows {
		t.Errorf("expected %d rows (capped), got %d", maxRows, len(rows))
	}
}
```

Note: the test file imports need to be merged into a single import block at the top. The implementer should consolidate all imports:

```go
import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"
)
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run TestExecuteQuery -v ./...
```

Expected: compilation error — `executeQuery` and `maxRows` undefined.

- [ ] **Step 3: Implement executeQuery in mcp.go**

Add to `api/mcp.go`:

```go
import (
	"context"
	"database/sql"
	"encoding/json"
)

const maxRows = 1000

// executeQuery runs a validated SQL query and returns the results as a JSON array string.
// Caps results at maxRows. Uses the provided context for timeout/cancellation.
func executeQuery(ctx context.Context, db *sql.DB, query string) (string, error) {
	rows, err := db.QueryContext(ctx, query)
	if err != nil {
		return "", fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	cols, err := rows.Columns()
	if err != nil {
		return "", fmt.Errorf("columns: %w", err)
	}

	var results []map[string]interface{}
	count := 0

	for rows.Next() {
		if count >= maxRows {
			break
		}

		values := make([]interface{}, len(cols))
		ptrs := make([]interface{}, len(cols))
		for i := range values {
			ptrs[i] = &values[i]
		}

		if err := rows.Scan(ptrs...); err != nil {
			return "", fmt.Errorf("scan: %w", err)
		}

		row := make(map[string]interface{}, len(cols))
		for i, col := range cols {
			val := values[i]
			// Convert []byte to string for JSON readability.
			if b, ok := val.([]byte); ok {
				row[col] = string(b)
			} else {
				row[col] = val
			}
		}

		results = append(results, row)
		count++
	}

	if err := rows.Err(); err != nil {
		return "", fmt.Errorf("rows: %w", err)
	}

	if results == nil {
		return "[]", nil
	}

	out, err := json.Marshal(results)
	if err != nil {
		return "", fmt.Errorf("marshal: %w", err)
	}

	result := string(out)
	if count >= maxRows {
		result += fmt.Sprintf("\n\n[Warning: results truncated to %d rows]", maxRows)
	}

	return result, nil
}
```

Consolidate imports at the top of `mcp.go` into a single block.

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run TestExecuteQuery -v ./...
```

Expected: all tests PASS.

- [ ] **Step 5: Commit**

```bash
cd /Users/claude/damsac-studio && git add api/mcp.go api/mcp_test.go
git commit -m "feat: add SQL query executor with row limit and timeout"
```

---

### Task 5: Wire up MCP server and tool handler

**Files:**
- Modify: `api/mcp.go`
- Modify: `api/mcp_test.go`

- [ ] **Step 1: Write the failing test for the MCP tool handler**

Append to `api/mcp_test.go`:

Add `"net/http"`, `"net/http/httptest"`, and `"io"` to the test file's import block.

```go
func TestMCPHandler_AuthReject(t *testing.T) {
	db := setupTestDB(t)
	keys := map[string]string{"testkey": "test-app"}
	authMW := APIKeyAuth(keys)
	handler := authMW(newMCPHandler(db))

	// Request without API key should be rejected.
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run "TestMCPHandler" -v ./...
```

Expected: compilation error — `newMCPHandler` undefined.

- [ ] **Step 3: Implement newMCPHandler in mcp.go**

Add to `api/mcp.go`:

```go
// QueryInput is the input schema for the query tool.
type QueryInput struct {
	SQL string `json:"sql" jsonschema:"description=A SQL SELECT statement to execute against the analytics database"`
}

const toolDescription = `Query the damsac-studio analytics database. Returns JSON rows.

Schema:
  events (
    id TEXT PRIMARY KEY,          -- UUID
    app_id TEXT NOT NULL,         -- e.g. "murmur-ios"
    event TEXT NOT NULL,          -- e.g. "llm.request", "credits.charged", "entry.created"
    timestamp TEXT NOT NULL,      -- RFC3339
    properties TEXT DEFAULT '{}', -- JSON: cost_micros, tokens_in, tokens_out, model, request_id, etc.
    context TEXT DEFAULT '{}',    -- JSON: device_id, app_version, os_version, etc.
    created_at TEXT NOT NULL      -- server receive time
  )

  Indexes: (timestamp), (app_id, timestamp), (event, timestamp)

  Common properties by event type:
    llm.request: cost_micros, tokens_in, tokens_out, model, request_id, call_type, latency_ms
    credits.charged: credits, balance_after, request_id
    entry.created: (varies)

  Use json_extract() for properties/context fields.
  Example: SELECT json_extract(properties, '$.cost_micros') FROM events WHERE event = 'llm.request'`

// newMCPHandler creates the MCP Streamable HTTP handler with the query tool registered.
func newMCPHandler(db *sql.DB) http.Handler {
	server := mcp.NewServer(&mcp.Implementation{
		Name:    "damsac-studio",
		Version: "0.1.0",
	}, nil)

	mcp.AddTool(server, &mcp.Tool{
		Name:        "query",
		Description: toolDescription,
	}, func(ctx context.Context, req *mcp.CallToolRequest, input QueryInput) (*mcp.CallToolResult, any, error) {
		if err := validateQuery(input.SQL); err != nil {
			return &mcp.CallToolResult{
				Content: []mcp.Content{
					&mcp.TextContent{Text: fmt.Sprintf("Error: %v", err)},
				},
				IsError: true,
			}, nil, nil
		}

		queryCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()

		result, err := executeQuery(queryCtx, db, input.SQL)
		if err != nil {
			return &mcp.CallToolResult{
				Content: []mcp.Content{
					&mcp.TextContent{Text: fmt.Sprintf("Error: %v", err)},
				},
				IsError: true,
			}, nil, nil
		}

		return &mcp.CallToolResult{
			Content: []mcp.Content{
				&mcp.TextContent{Text: result},
			},
		}, nil, nil
	})

	return mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		return server
	}, &mcp.StreamableHTTPOptions{
		Stateless: true,
	})
}

```

Final consolidated imports for `mcp.go` (replace existing import block):

```go
import (
	"context"
	"database/sql"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -run "TestMCPHandler" -v ./...
```

Expected: both tests PASS (auth reject returns 401, initialize returns 200 with server name).

- [ ] **Step 5: Run all tests to verify nothing is broken**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -v ./...
```

Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
cd /Users/claude/damsac-studio && git add api/mcp.go api/mcp_test.go
git commit -m "feat: add MCP server with query tool registration"
```

---

### Task 6: Mount MCP handler in main.go

**Files:**
- Modify: `api/main.go`

- [ ] **Step 1: Add read-only DB and MCP route to main.go**

After the existing `store` creation (line 36 `defer store.Close()`) and before `broker := NewBroker()`, add:

```go
	roDB, err := OpenReadOnlyDB(cfg.DataDir)
	if err != nil {
		log.Fatalf("read-only db: %v", err)
	}
	defer roDB.Close()
```

After the existing route registrations (after line 123 `mux.Handle("/projects", ...)`), add:

```go
	// MCP endpoint -- protected by API key middleware.
	mcpHandler := newMCPHandler(roDB)
	mux.Handle("/mcp", authMiddleware(mcpHandler))
```

- [ ] **Step 2: Verify build**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go build ./...
```

Expected: clean build.

- [ ] **Step 3: Run all tests**

```bash
cd /Users/claude/damsac-studio/api && nix develop --command go test -v ./...
```

Expected: all tests PASS.

- [ ] **Step 4: Commit**

```bash
cd /Users/claude/damsac-studio && git add api/main.go
git commit -m "feat: mount MCP endpoint on /mcp behind API key auth"
```

---

### Task 7: Update Nix build

**Files:**
- Modify: `flake.nix`

- [ ] **Step 1: Update vendorHash**

The Go dependency change means the Nix vendorHash is stale. Build and get the new hash:

```bash
cd /Users/claude/damsac-studio && nix build 2>&1 | grep "got:"
```

Update `flake.nix` line 19 with the new hash from the error output.

- [ ] **Step 2: Verify Nix build succeeds**

```bash
cd /Users/claude/damsac-studio && nix build
```

Expected: clean build, produces `result/bin/damsac-studio`.

- [ ] **Step 3: Commit**

```bash
cd /Users/claude/damsac-studio && git add flake.nix
git commit -m "build: update vendorHash for MCP SDK dependency"
```

---

### Task 8: Manual integration test

- [ ] **Step 1: Start the dev server**

```bash
cd /Users/claude/damsac-studio/api && API_KEYS=testkey:test DASHBOARD_PASSWORD_FILE=<(echo testpass) DEV=1 nix develop --command go run .
```

- [ ] **Step 2: Verify MCP endpoint responds**

In another terminal, test the MCP endpoint with a raw JSON-RPC initialize request:

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-API-Key: testkey" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}' | head -20
```

Expected: JSON response with server info and capabilities.

- [ ] **Step 3: Test tools/list**

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "X-API-Key: testkey" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' | head -20
```

Expected: JSON listing the `query` tool with its description.

- [ ] **Step 4: Test auth rejection**

```bash
curl -s -X POST http://localhost:8080/mcp \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' | head -5
```

Expected: 401 Unauthorized.

- [ ] **Step 5: Connect Claude Code**

```bash
claude mcp add --transport http \
  --header "X-API-Key: testkey" \
  --scope local \
  studio http://localhost:8080/mcp
```

Then start Claude Code and ask it to query events. Verify the tool appears and works.

- [ ] **Step 6: Clean up test MCP config when done**

```bash
claude mcp remove studio
```
