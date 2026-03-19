# damsac Studio Analytics MVP — Design Spec

**Date:** 2026-03-15
**Status:** Draft
**Supersedes:** `docs/spec.md` (PostgreSQL + Docker Compose + Grafana design)
**Scope:** Self-hosted analytics platform — Go + SQLite + htmx, deployed as a NixOS module

## Context

Murmur needs visibility into LLM token usage and user behavior before TestFlight. Rather than adopting a SaaS tool, we're building a self-hosted platform. The original spec targeted PostgreSQL + Grafana + Docker Compose on a VPS. This revision simplifies: SQLite for storage, a custom htmx dashboard instead of Grafana, and a Nix flake with a NixOS module instead of containers.

### Key Decisions

- **Single Go binary.** Serves ingest API, dashboard, and health check. No external services.
- **SQLite.** Single file on disk. Pure Go driver (`modernc.org/sqlite`) — no CGO.
- **htmx dashboard.** Custom admin UI with real-time SSE updates. No Grafana.
- **Nix flake.** `buildGoModule` for the binary, NixOS module for deployment, dev shell for local work.
- **No containers.** Nix handles the build and service management.
- **MVP = raw data.** Ingest, store, view. No charts or aggregations yet. Data pipeline design comes later.

## System Architecture

```
┌─────────────┐     ┌──────────────────────────────┐
│  iOS SDK     │────▶│  damsac-studio (single binary)│
│  (Swift)     │POST │                              │
└─────────────┘     │  /v1/events    → ingest API  │
                    │  /dashboard/*  → htmx UI     │
                    │  /v1/health    → health check │
                    │                              │
                    │  SQLite (single file on disk) │
                    └──────────────────────────────┘
```

**Deployment:** NixOS module on a VPS. Dev shell for local development.

## Component 1: Ingest API

### Endpoints

| Method | Path | Auth | Purpose |
|--------|------|------|---------|
| `POST` | `/v1/events` | API key | Receive event batch |
| `GET` | `/v1/health` | None | Liveness check |

### Event Payload

```json
{
  "events": [
    {
      "id": "uuid",
      "app_id": "murmur-ios",
      "event": "llm.request",
      "timestamp": "2026-03-14T10:30:00Z",
      "properties": {
        "tokens_in": 1523,
        "tokens_out": 487,
        "model": "claude-sonnet-4-6"
      },
      "context": {
        "app_version": "1.0.0",
        "os_version": "19.0",
        "device_model": "iPhone17,1"
      }
    }
  ]
}
```

### Validation (MVP)

- **Max body size:** 1MB
- **Max batch size:** 100 events
- **Required fields:** `event` (non-empty string), `timestamp` (valid RFC3339)
- **`app_id`:** Must match the app ID mapped to the API key. Reject with `403` if mismatched.
- **`id`:** Optional. Server generates a UUID if omitted.

### Success Response

`202 Accepted` with body `{ "accepted": N }` where N is the number of events inserted.

### Error Responses

```json
{ "error": "description", "code": "VALIDATION_ERROR" }
```

| Status | Code | When |
|--------|------|------|
| `400` | `VALIDATION_ERROR` | Missing required fields, bad timestamp |
| `401` | `UNAUTHORIZED` | Missing or invalid API key |
| `403` | `FORBIDDEN` | API key does not match `app_id` |
| `413` | `PAYLOAD_TOO_LARGE` | Body > 1MB or batch > 100 events |

### Authentication

`X-API-Key` header. Keys configured as `key:app_id` pairs in the NixOS module (keys must not contain `:`). Constant-time comparison via `crypto/subtle`.

### Write Strategy

Direct insert per batch in a single transaction. No in-memory buffer. SQLite with WAL mode handles the volume of a single indie app without buffering complexity. `properties` and `context` fields are validated as valid JSON in Go (`json.Valid()`) before insert.

**Concurrency:** Use a write mutex or `_txlock=immediate` to serialize writes and avoid `SQLITE_BUSY` under concurrent ingest requests.

**Idempotency:** `INSERT OR IGNORE` on the UUID primary key — duplicate events from client retries are silently dropped.

## Component 2: SQLite Schema

```sql
CREATE TABLE events (
    id         TEXT PRIMARY KEY,
    app_id     TEXT NOT NULL,
    event      TEXT NOT NULL,
    timestamp  TEXT NOT NULL,
    properties TEXT DEFAULT '{}',
    context    TEXT DEFAULT '{}',
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE INDEX idx_events_time ON events (timestamp);
CREATE INDEX idx_events_app ON events (app_id, timestamp);
CREATE INDEX idx_events_event ON events (event, timestamp);
```

### Pragmas (set on connection)

```
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;
PRAGMA synchronous=NORMAL;
PRAGMA foreign_keys=ON;        -- forward-looking, no FKs in MVP schema
```

### Migration Strategy

MVP: schema created on startup if the DB doesn't exist. Add a proper migration system when schema starts evolving.

## Component 3: Dashboard

Admin-only htmx web UI at `/dashboard`.

### Authentication

Simple password auth. Login form sets a server-side session cookie (in-memory session map). Password configured via file path in the NixOS module (sops-nix / agenix friendly). Server restarts require re-login. Session cookie: HttpOnly, Secure, SameSite=Strict, 24-hour expiry.

### MVP Views

- **Events feed** — paginated table of recent events. Filter by app, event type, time range. htmx partial updates for filtering and pagination.
- **Event detail** — click a row to expand full properties and context JSON.

No charts or aggregations for MVP. The dashboard is a window into raw data, iterated on as the data pipeline is designed.

### Real-time Updates (SSE)

- `GET /dashboard/events/stream` — SSE endpoint, dashboard-auth required
- Ingest handler broadcasts to connected clients via a subscriber registry (each SSE connection registers its own channel; ingest handler fans out to all registered channels)
- SSE endpoint reads from its channel, writes rendered HTML fragments
- htmx `sse` extension swaps new rows into the events table
- Initial page load is normal HTTP; SSE layers live updates on top

No polling, no WebSockets, no external message broker.

### Tech

- `html/template` for server-side rendering
- htmx for partial page updates + SSE
- Minimal CSS (Pico CSS or hand-rolled)
- Static assets embedded in binary via `embed.FS`

## Component 4: Swift SDK

Swift package in `sdk/swift/`. Pure Swift, consumed by iOS apps as a package dependency.

### API Surface

```swift
StudioAnalytics.configure(
    appId: "murmur-ios",
    endpoint: "https://analytics.yourdomain.com",
    apiKey: "sk_murmur_live"
)

StudioAnalytics.track("llm.request", properties: [
    "tokens_in": 1523,
    "tokens_out": 487,
    "model": "claude-sonnet-4-6"
])
```

### Event Flow

```
Event captured
    │
    ▼
In-memory queue (cap: 1000, drop oldest when full)
    │
    ├──▶ Persist to JSON file in Library/Application Support/analytics/
    │
    ▼
Flush triggers:
  • 30-second timer (foreground)
  • 20-event threshold
  • App enters background (beginBackgroundTask)
  • NWPathMonitor: connectivity restored
    │
    ▼
POST /v1/events (batch of up to 50 events)
    │
    ├── 2xx: delete persisted events
    ├── 4xx: drop events (not retryable)
    └── 5xx/timeout: exponential backoff (1s → 60s cap), keep in queue
```

### Internals

- **Singleton** — thread-safe via Swift actor or internal lock
- **`configure()` before `track()`** — events before configure are silently dropped
- **Persistence** — JSON files in `Library/Application Support/analytics/`. One file per batch, 5MB disk cap, oldest deleted when exceeded.
- **Anonymous identity** — IDFV hashed with SHA-256 (salted with `appId`). Sent as `device_id` in the `context` object.
- **Session tracking** — 5-minute inactivity timeout, new UUID per session. Sent as `session_id` in the `context` object.
- **Device context** — app version, build number, OS version, device model, locale, timezone, SDK version
- **Network** — `NWPathMonitor` for connectivity. Circuit breaker: 5 consecutive failures → pause 60s.

## Component 5: Nix Flake & NixOS Module

### Flake Outputs

```
flake.nix
├── packages.default     → Go binary (buildGoModule)
├── nixosModules.default → systemd service + config
├── devShells.default    → Go, sqlite3, air (live reload)
```

### NixOS Module Config

```nix
services.damsac-studio = {
  enable = true;
  port = 8080;
  dataDir = "/var/lib/damsac-studio";
  apiKeys = [ "sk_murmur:murmur-ios" ];
  dashboardPasswordFile = "/run/secrets/damsac-dashboard-pw";
};
```

### Configuration Interface

The binary reads all configuration from environment variables. The NixOS module sets these via systemd `Environment=` / `EnvironmentFile=` directives.

| Variable | Description | Default |
|----------|-------------|---------|
| `PORT` | Listen port | `8080` |
| `DATA_DIR` | Directory for SQLite DB file | `.` |
| `API_KEYS` | Comma-separated `key:app_id` pairs | (required) |
| `DASHBOARD_PASSWORD_FILE` | Path to file containing dashboard password | (required) |

### Module Implementation

- Creates a dedicated systemd service
- `DynamicUser`, `StateDirectory`, `ProtectSystem=strict` for hardening
- `dataDir` holds the SQLite database file
- `dashboardPasswordFile` supports secret management (sops-nix / agenix)

### Dev Shell

- Go toolchain
- `sqlite3` CLI
- `air` for live reload
- Dev run script with default config

## Project Layout

```
damsac-studio/
  flake.nix
  flake.lock
  api/
    main.go
    handler.go          # ingest + health endpoints
    store.go            # SQLite operations
    dashboard.go        # dashboard routes + SSE
    auth.go             # API key auth + dashboard session auth
    config.go           # config loading
    templates/
      layout.html
      login.html
      events.html
      event_row.html    # htmx partial for SSE
    static/
      style.css
      htmx.min.js
    go.mod
    go.sum
  sdk/
    swift/
      Package.swift
      Sources/StudioAnalytics/
      Tests/StudioAnalyticsTests/
  module.nix            # NixOS module definition
  docs/
```

## Non-Goals (MVP)

- Charts, aggregations, or computed dashboards (data pipeline designed separately)
- User accounts or multi-tenant auth
- Rate limiting (single app, trusted clients)
- Schema migrations system
- Data retention / cleanup automation
- Backup automation
- Session replay, A/B testing, feature flags
