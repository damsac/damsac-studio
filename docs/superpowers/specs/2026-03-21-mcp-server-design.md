# MCP Server for damsac-studio

## Summary

Add an MCP (Model Context Protocol) Streamable HTTP endpoint to damsac-studio, giving Claude Code instances read access to the analytics database via a single `query` tool. Both dam and sac's local Claudes connect to the same hosted server and can answer arbitrary questions about event data, LLM costs, user activity, and trends.

## Motivation

dam and sac work independently with Claude Code and periodically sync. Right now, answering questions about app analytics ("what's our LLM spend?", "how many users today?", "what errors are showing up?") requires opening the dashboard in a browser. An MCP server lets Claude answer these directly, using the full power of SQL against the real data.

This is the foundation for a more capable MCP server over time — starting with one tool that's immediately useful rather than speculating on features.

## Architecture

The MCP endpoint is embedded in the existing damsac-studio binary, not a separate service.

```
damsac-studio (single Go binary)
├── /v1/health          — health check (no auth)
├── /v1/events          — event ingest (API key auth, write)
├── /dashboard/*        — dashboard (session auth)
├── /projects           — GitHub project board (session auth)
└── /mcp                — MCP Streamable HTTP (API key auth, read-only)
```

### Why embedded

- Fits the "single stateless binary" philosophy
- Reuses existing config, deploy, and NixOS module patterns
- No new infrastructure to manage
- SQLite WAL mode supports concurrent readers alongside the write connection

### Read-only database connection

The MCP handler gets its own `*sql.DB` opened in read-only mode. This is separate from the main write connection used by ingest. Read-only mode is enforced at the SQLite level — even if a bug allows a non-SELECT query through, SQLite will reject it.

**Important:** The `modernc.org/sqlite` driver strips query parameters from plain path DSNs. The read-only connection **must** use `file:` URI format for `?mode=ro` to take effect:

```go
dsn := fmt.Sprintf("file:%s?mode=ro&_pragma=busy_timeout(5000)", filepath.Join(dataDir, "studio.db"))
db, err := sql.Open("sqlite", dsn)
```

Using DSN-level `_pragma` parameters means each connection in the pool gets the pragma applied automatically, so unlike the write connection (which uses `MaxOpenConns(1)` to guarantee pragmas), the read-only pool can allow multiple concurrent connections for parallel queries from multiple Claude instances.

**Startup ordering:** The read-only DB must be opened after the write DB (which creates the file and runs migrations). The read-only connection skips migration entirely.

## Tool: `query`

One tool. Takes a SQL SELECT statement, returns JSON rows.

### Parameters

| Name | Type   | Required | Description |
|------|--------|----------|-------------|
| sql  | string | yes      | A SQL SELECT statement |

### Tool description (baked into MCP registration)

```
Query the damsac-studio analytics database. Returns JSON rows.

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
  Example: SELECT json_extract(properties, '$.cost_micros') FROM events WHERE event = 'llm.request'
```

### Safety guardrails

1. **Read-only connection**: SQLite `file:` URI with `?mode=ro` — the primary safety net. Even if query validation is bypassed, SQLite rejects writes.
2. **Query validation** (defense-in-depth):
   - Reject queries containing semicolons (prevents multi-statement attacks like `SELECT 1; DROP TABLE events`)
   - Accept queries starting with `SELECT` or `WITH` (for CTE support)
   - For `WITH` queries, verify the final statement after CTEs is a `SELECT`
   - Block keywords: INSERT, UPDATE, DELETE, DROP, ALTER, ATTACH, DETACH, PRAGMA
3. **Row limit**: Cap results at 1000 rows. If the query returns more, truncate and include a warning in the response.
4. **Query timeout**: 5-second context deadline. Long-running queries are cancelled.

### Response format

Success:
```json
{
  "content": [{"type": "text", "text": "[{\"event\": \"llm.request\", ...}, ...]"}]
}
```

Error (bad SQL, timeout, etc.):
```json
{
  "content": [{"type": "text", "text": "Error: <message>"}],
  "isError": true
}
```

## Authentication

Reuses the existing `API_KEYS` env var and `APIKeyAuth` middleware from `auth.go`. Same keys that work for ingest work for MCP — the read-only SQLite connection is the safety boundary, not the key. No new env vars or NixOS options needed.

Constant-time comparison, `app_id` extracted from the key pair and available for logging which developer is querying.

### Claude Code connection

```bash
# Dev (local)
claude mcp add --transport http \
  --header "X-API-Key: your-existing-key" \
  --scope user \
  studio http://localhost:8080/mcp

# Prod (VPS)
claude mcp add --transport http \
  --header "X-API-Key: your-existing-key" \
  --scope user \
  studio https://studio.yourdomain.com/mcp
```

## Protocol

Uses MCP Streamable HTTP transport via the Go MCP SDK (`github.com/modelcontextprotocol/go-sdk`).

The SDK provides an HTTP handler (verify exact API name against the SDK at implementation time — the Go SDK is evolving and the function may be in a sub-package like `mcphttp`). The handler manages:
- POST `/mcp` — JSON-RPC requests (initialize, tools/list, tools/call)
- GET `/mcp` — SSE stream for server-initiated messages
- DELETE `/mcp` — session teardown

Session management is handled by the SDK. For MVP, stateless mode is fine (no session persistence across restarts).

The existing server's `WriteTimeout: 0` (set for SSE support) is also required by MCP Streamable HTTP's SSE channel — no change needed.

## Changes

### New files

| File | Purpose |
|------|---------|
| `api/mcp.go` | MCP server setup, `query` tool registration, SQL executor, auth middleware |

### Modified files

| File | Change |
|------|--------|
| `api/main.go` | Open read-only DB (after write DB), create MCP handler, mount `/mcp` route, defer close read-only DB |
| `api/store.go` | Add `OpenReadOnlyDB(dataDir)` that returns a `*sql.DB` (not a `*Store`) — uses `file:` URI with `?mode=ro`, skips migration, allows concurrent connections |
| `go.mod` / `go.sum` | Add `github.com/modelcontextprotocol/go-sdk` dependency |

### Not changed

All existing routes, auth, dashboard, ingest, templates, and static files remain untouched.

## Future

This design is deliberately narrow — one tool, one auth mechanism. The foundation (MCP SDK, Streamable HTTP, tool registration pattern) supports adding more tools later:

- Write tools (create events, update project state)
- Message passing between Claudes
- GitHub integration tools (PR review, issue management)
- Schema introspection tool (so Claude can discover new tables)

These are not part of this spec.

## Maintenance note

The `query` tool description bakes in the full schema. If the database schema changes (new tables, new event types, new property keys), update the tool description in `api/mcp.go` to match.
