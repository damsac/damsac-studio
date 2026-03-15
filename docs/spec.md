# damsac Studio Analytics — Design Spec

**Date:** 2026-03-14
**Status:** Approved
**Scope:** Self-hosted analytics platform for indie dev studio, starting with event analytics and LLM cost tracking

## Context

Murmur has zero analytics infrastructure. Before TestFlight, we need visibility into LLM token usage/costs and user behavior. Rather than adopting a SaaS tool, we're building a self-hosted platform that serves all damsac apps — analytics first, growing into a full studio management dashboard.

### Decisions

- **Self-hosted, no paid services.** Open-source or custom-built only.
- **Go backend.** Single binary, low resource footprint, stdlib HTTP.
- **PostgreSQL + JSONB.** One events table, flexible schema, scales to millions of rows.
- **Grafana dashboards.** Connects to Postgres natively. No custom UI needed initially.
- **VPS hosting.** Hetzner CX22 (~$4/mo): 2 vCPU, 4GB RAM, 40GB disk.
- **Multi-app from day one.** `app_id` on every event. Dashboard variables per app.

## System Architecture

```
┌─────────────┐     ┌─────────────────┐     ┌─────────────┐
│  iOS SDK     │────▶│  Go Ingest API  │────▶│  PostgreSQL  │
│  (per app)   │POST │  (single binary)│COPY │  (JSONB)     │
└─────────────┘     └─────────────────┘     └──────┬───────┘
                                                   │
                                            ┌──────▼───────┐
                                            │   Grafana     │
                                            │  (dashboards) │
                                            └──────────────┘
```

All four services run on a single VPS via Docker Compose. Caddy reverse proxy for TLS (Let's Encrypt).

## Component 1: Go Ingest API

Single binary. Go 1.22+ stdlib `net/http` (method routing built in — no framework).

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `POST` | `/v1/events` | Receive event batch, buffer, return `202 Accepted` |
| `GET` | `/v1/health` | Liveness check for monitoring |

### Event Payload

```json
{
  "events": [
    {
      "id": "uuid",
      "app_id": "murmur-ios",
      "event": "llm.request",
      "timestamp": "2026-03-14T10:30:00Z",
      "session_id": "uuid",
      "device_id": "hashed-idfv",
      "properties": {
        "tokens_in": 1523,
        "tokens_out": 487,
        "model": "claude-sonnet-4-6",
        "latency_ms": 2100,
        "tool": "compose_view"
      },
      "context": {
        "app_version": "1.0.0",
        "build_number": "42",
        "os_version": "19.0",
        "device_model": "iPhone17,1",
        "locale": "en_US",
        "timezone": "America/Chicago",
        "sdk_version": "0.1.0"
      }
    }
  ]
}
```

### Request Validation

- **Max body size:** 1MB per request (enforced via `http.MaxBytesReader`)
- **Max batch size:** 100 events per request. Reject with `413` if exceeded.
- **Required fields:** `event` (non-empty string), `timestamp` (valid RFC3339, within 7 days of server time)
- **Optional fields:** `id` (UUID), `session_id`, `device_id`, `properties`, `context`
- **JSONB depth limit:** max 3 levels of nesting in `properties` and `context`
- **`app_id` validation:** must match the app ID mapped to the API key. If mismatched, reject with `403`.
- If `id` is omitted, the server generates one via `gen_random_uuid()`. If provided, it is used as-is — **enabling idempotent retries** (duplicate IDs are upserted, not duplicated).

### Error Responses

All errors return JSON:

```json
{ "error": "description", "code": "VALIDATION_ERROR" }
```

| Status | Code | When |
|--------|------|------|
| `400` | `VALIDATION_ERROR` | Missing required fields, bad timestamp, nesting too deep |
| `401` | `UNAUTHORIZED` | Missing or invalid API key |
| `403` | `FORBIDDEN` | API key does not match `app_id` |
| `413` | `PAYLOAD_TOO_LARGE` | Body > 1MB or batch > 100 events |
| `429` | `RATE_LIMITED` | Per-key rate limit exceeded (100 req/s) |
| `503` | `BUFFER_FULL` | Server buffer at capacity, client should retry |

### Authentication

API key in `X-API-Key` header. Keys mapped to app IDs in a `.env` file (gitignored). Constant-time comparison via `crypto/subtle`. Per-key rate limit: 100 requests/second.

`GET /v1/health` is unauthenticated. Returns only `{"status": "ok"}` — no internal state.

### Buffering Strategy

In-memory buffer with dual-trigger flush to Postgres:

- **Size trigger:** flush at 500 events
- **Time trigger:** flush every 5 seconds
- **Max buffer size:** 10,000 events. When full, return `503 BUFFER_FULL` to clients (backpressure).
- **Shutdown trigger:** drain buffer on SIGTERM/SIGINT
- **Insert method:** pgx `CopyFrom` (PostgreSQL COPY protocol — fastest bulk insert)
- **Postgres down:** flush fails, events stay in buffer. Log error. Retry on next flush cycle. If buffer fills during extended outage, backpressure kicks in (503).
- **Data loss window:** max 5 seconds on crash. Acceptable for analytics.

The HTTP handler returns `202 Accepted` immediately after buffering. Ingestion latency is sub-millisecond.

### Database Driver

pgx v5 (native interface, not database/sql). Reasons:
- lib/pq is deprecated (their README says "use pgx")
- Native pgx is ~50% faster than lib/pq
- Native JSONB type support and COPY protocol

### Project Layout

```
studio-analytics/
  api/                     # Go ingest API (flat structure)
    main.go                # Entry point, wire dependencies
    handler.go             # HTTP handlers
    store.go               # PostgreSQL operations (pgx)
    buffer.go              # In-memory event buffer + flush
    middleware.go           # API key auth middleware
    config.go              # Config loading (YAML/env)
    go.mod
    go.sum
    Dockerfile
  sdk/
    swift/                 # iOS SDK (Swift package)
      Package.swift
      Sources/StudioAnalytics/
      Tests/StudioAnalyticsTests/
  deploy/                  # Docker Compose, Caddyfile, .env.example, schema.sql
  migrations/              # golang-migrate SQL files
  grafana/
    provisioning/          # Dashboard JSON, datasource config
```

Go API uses flat single-package structure. Grow when needed. No premature `cmd/internal/pkg`.

## Component 2: PostgreSQL Schema

### Events Table

```sql
CREATE TABLE events (
    id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    app_id      TEXT NOT NULL,
    event       TEXT NOT NULL,
    timestamp   TIMESTAMPTZ NOT NULL,
    session_id  UUID,
    device_id   TEXT,
    properties  JSONB DEFAULT '{}',
    context     JSONB DEFAULT '{}',
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_events_time ON events (timestamp);
CREATE INDEX idx_events_app ON events (app_id, timestamp);
CREATE INDEX idx_events_event ON events (event, timestamp);
```

### Index Strategy

- B-tree on `timestamp` — every Grafana query filters by time range
- Composite `(app_id, timestamp)` — multi-app dashboard queries
- Composite `(event, timestamp)` — event-type filtering
- **No GIN index on JSONB** to start. Write overhead not worth it at low volume. Add when needed for property-based filtering.

### Schema Migrations

Phase 1 schema is created via Docker entrypoint init (`01-schema.sql`). For subsequent schema changes (new tables, partitioning, materialized views), use [golang-migrate](https://github.com/golang-migrate/migrate) with numbered SQL files in a `migrations/` directory. Add a `migrate` subcommand to the Go binary or run migrations as a Docker entrypoint step.

### Scaling Path

1. **Partition by month** when table exceeds ~10M rows: `PARTITION BY RANGE (timestamp)`
2. **Materialized views** for expensive aggregations (daily summaries, cost rollups). Refresh every 5 minutes via cron.
3. **Swap to ClickHouse** if Postgres can't keep up. Same Grafana dashboards, different connection string.

## Component 3: iOS SDK (StudioAnalytics)

Swift package in the `sdk/swift/` directory of the studio-analytics repo. Pure Swift, no Rust/UniFFI for now — can be rewritten in Rust later when Android is needed. Consumed by iOS apps as a Swift package dependency (local path or git URL).

**Future Rust migration path:** The public API (`StudioAnalytics.configure()`, `.track()`, etc.) is designed to be stable regardless of implementation language. If the core is later rewritten in Rust with UniFFI-generated Swift bindings, the calling code in apps does not change.

### API Surface

```swift
// Setup — call once in App init
StudioAnalytics.configure(
    appId: "murmur-ios",
    endpoint: "https://analytics.yourdomain.com",
    apiKey: "sk_live_..."
)

// Generic event tracking
StudioAnalytics.track("entry.created", properties: [
    "category": "todo",
    "source": "voice",
    "audio_duration_ms": 4500
])

// LLM-specific helper
StudioAnalytics.trackLLM(
    tool: "compose_view",
    model: "claude-sonnet-4-6",
    tokensIn: 1523,
    tokensOut: 487,
    latencyMs: 2100
)
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
  • App enters background (beginBackgroundTask, up to 30s)
  • NWPathMonitor: connectivity restored after offline
    │
    ▼
POST /v1/events (batch of up to 50 events)
    │
    ├── 2xx: delete persisted events
    ├── 4xx: drop events (client error, not retryable)
    └── 5xx/timeout: exponential backoff (1s, 2s, 4s... cap 60s), keep in queue
```

### Configuration Behavior

`StudioAnalytics` is a singleton (thread-safe via Swift actor or internal lock).

- `configure()` must be called before `track()`. Events sent before `configure()` are silently dropped.
- Calling `configure()` a second time replaces the configuration (allows test/prod switching).
- All internal work (persistence, network) runs on a background serial queue.

### Persistence

JSON files in `Library/Application Support/analytics/`. No SQLite dependency.

- **One file per flush batch:** each flush attempt writes a numbered JSON file (e.g., `batch-0001.json`). Contains an array of event objects.
- **On successful upload:** the batch file is deleted.
- **On failure:** the batch file stays on disk and is retried on next flush.
- **Corruption recovery:** if a batch file fails JSON decoding on load, it is deleted (data loss is acceptable for analytics).
- **Max disk usage:** 5MB cap. When exceeded, oldest batch files are deleted to make room.
- **App extensions:** not supported in Phase 1. SDK is app-only.
- Not in Documents (would be visible in Files app and backed up to iCloud)
- Not in UserDefaults (not designed for growing data)

### Anonymous Identity

- **IDFV** (`identifierForVendor`) — no ATT required, scoped to vendor (developer team)
- SHA-256 hashed with the `appId` string as salt before sending (deterministic, no secret — the goal is to prevent cross-app correlation of raw IDFVs, not cryptographic secrecy)
- Resets only if user deletes ALL apps from the developer team
- Cannot be used for cross-vendor tracking (Apple policy)

### Session Tracking

- 5-minute inactivity timeout (Amplitude's default, industry standard)
- New session UUID generated on:
  - First event if no active session
  - App returns to foreground after > 5 minutes in background
  - No event for > 5 minutes
- `session_id` attached to every event
- Explicit `session.start` event emitted. `session.end` is best-effort (app may be killed by OS before it fires). Server-side can infer session end from inactivity if needed.

### Device Context (No ATT Required)

Attached to every event in the `context` object:

| Field | Source |
|-------|--------|
| `app_version` | `CFBundleShortVersionString` |
| `build_number` | `CFBundleVersion` |
| `os_version` | `ProcessInfo.operatingSystemVersion` |
| `device_model` | `utsname.machine` (e.g., "iPhone17,1") |
| `locale` | `Locale.current.identifier` |
| `timezone` | `TimeZone.current.identifier` |
| `sdk_version` | StudioAnalytics version string |

### Network Handling

- `NWPathMonitor` on a background `DispatchQueue` for connectivity state
- Events always enqueue locally regardless of network state
- Flush is a no-op when offline — events stay on disk
- Immediate flush triggered when connectivity is restored
- Circuit breaker: after 5 consecutive failures, pause retries for 60 seconds

## Component 4: Grafana Dashboards

Grafana OSS connects directly to PostgreSQL as a data source. No intermediate layer.

### Template Variables

- `$app_id` — dropdown of all apps, filters every panel
- `$__interval` — auto time bucketing from Grafana

### Starter Dashboards

**LLM Costs:**
```sql
-- Token usage over time
SELECT
  $__timeGroupAlias(timestamp, $__interval),
  sum((properties->>'tokens_in')::int) as input_tokens,
  sum((properties->>'tokens_out')::int) as output_tokens
FROM events
WHERE $__timeFilter(timestamp)
  AND app_id = '$app_id'
  AND event = 'llm.request'
GROUP BY 1
ORDER BY 1
```

- Tokens per request over time (line chart)
- Cost breakdown by model/tool (pie chart)
- Daily spend trend (bar chart)
- Average latency by tool (stat panel)

**App Usage:**
- Events per day (time series)
- Unique sessions per day (time series)
- Voice vs text input ratio (pie chart)
- Entry category distribution (bar chart)
- Top events by count (table)

**Health:**
- Error rate (events with `event = '*.error'`)
- API latency percentiles
- Events ingested per minute (rate)

### Grafana Tips

- Use `$__timeFilter(timestamp)` macro — auto-applies dashboard time range
- Set `max data points` on panels to prevent requesting millions of rows
- Set `min interval` to match data granularity (e.g., `1m`)

## Deployment

### Docker Compose

```yaml
services:
  api:
    build: ./api
    ports: ["8080:8080"]
    env_file: .env
    depends_on:
      postgres:
        condition: service_healthy
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  postgres:
    image: postgres:17
    env_file: .env
    volumes:
      - pgdata:/var/lib/postgresql/data
      - ./schema.sql:/docker-entrypoint-initdb.d/01-schema.sql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U analytics"]
      interval: 5s
      timeout: 5s
      retries: 5
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  grafana:
    image: grafana/grafana-oss:11.4.0
    ports: ["3000:3000"]
    volumes:
      - grafana-data:/var/lib/grafana
      - ./grafana/provisioning:/etc/grafana/provisioning
    env_file: .env
    depends_on:
      - postgres
    restart: unless-stopped
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  caddy:
    image: caddy:2
    ports: ["80:80", "443:443"]
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy-data:/data
    restart: unless-stopped

volumes:
  pgdata:
  grafana-data:
  caddy-data:
```

### .env File (gitignored)

```bash
# Postgres
POSTGRES_DB=analytics
POSTGRES_USER=analytics
POSTGRES_PASSWORD=<generate-a-real-password>

# Go API
DATABASE_URL=postgres://analytics:<same-password>@postgres:5432/analytics?sslmode=disable
API_KEYS=sk_murmur_live:murmur-ios

# Grafana
GF_SECURITY_ADMIN_PASSWORD=<generate-a-real-password>
```

A `.env.example` is committed with placeholder values. `.env` is in `.gitignore`.

### Caddyfile

```
analytics.yourdomain.com {
    # API: public (authenticated by API key)
    reverse_proxy /v1/* api:8080

    # Grafana: behind basic auth
    basicauth {
        admin <hashed-password>
    }
    reverse_proxy grafana:3000
}
```

Grafana is behind Caddy basic auth as a second layer. Internal Docker traffic (API to Postgres, Grafana to Postgres) is unencrypted — acceptable for same-host Docker networking.

### VPS Requirements

- **Hetzner CX22:** 2 vCPU, 4GB RAM, 40GB disk, ~$4/mo
- Docker + Docker Compose pre-installed
- Domain pointed at VPS IP

### Backups

- **Cron job:** `pg_dump` daily to a local directory, compressed
- **Offsite:** rsync or rclone to Backblaze B2 (free 10GB tier) or Hetzner Storage Box
- **Retention:** 7 daily backups, 4 weekly backups
- **Restore procedure:** `pg_restore` from latest dump into a fresh Postgres container

### Data Retention

- Events older than 90 days are deleted via a weekly cron job: `DELETE FROM events WHERE timestamp < now() - interval '90 days'`
- Adjust as needed — 90 days is a starting point for a small VPS disk
- Grafana materialized views for long-term trends survive the raw data deletion

### Monitoring

- **External uptime check:** UptimeRobot free tier (or cron + curl from another machine) hitting `GET /v1/health`
- **Docker log rotation:** configured per-service (10MB max, 3 files) to prevent disk exhaustion
- **Disk usage alert:** cron script that checks `df` and sends a webhook/email if usage exceeds 80%

## Conventions

### Model Naming

Use the provider-prefixed format from the codebase: `anthropic/claude-sonnet-4.6` (not `claude-sonnet-4-6`). The SDK should pass through whatever string the app provides — no normalization.

## Events to Track in Murmur (Phase 1)

### LLM Events

| Event | Properties |
|-------|-----------|
| `llm.request` | `tokens_in`, `tokens_out`, `model`, `latency_ms`, `tool`, `streaming`. Emitted for every LLM call. |
| `llm.error` | `error_type`, `status_code`, `model` |
| `llm.composition` | `variant` (scanner/navigator), `items_count`. Emitted alongside `llm.request` for home composition calls — provides composition-specific context. |

### User Behavior Events

| Event | Properties |
|-------|-----------|
| `session.start` | (none — context provides device info) |
| `session.end` | `duration_s`, `events_count` |
| `recording.start` | `source` (voice/text) |
| `recording.complete` | `duration_ms`, `transcript_length` |
| `entry.created` | `category`, `source`, `audio_duration_ms` |
| `entry.completed` | `category`, `age_hours` |
| `entry.deleted` | `category`, `age_hours` |
| `entry.edited` | `category`, `field` (title/content/category/priority) |
| `home.variant_switch` | `from`, `to` |
| `home.tab_switch` | `tab` (focus/all) |
| `credits.charged` | `credits` (integer, internal unit), `balance_after` (integer) |

### Error Events

| Event | Properties |
|-------|-----------|
| `error.transcription` | `error_type` |
| `error.parse` | `error_type`, `raw_response_length` |
| `error.network` | `endpoint`, `status_code` |

## Growth Path

| Phase | Adds | Effort |
|-------|------|--------|
| **1 (now)** | Event analytics + LLM costs | This spec |
| **2** | Structured app logs | New `POST /v1/logs` endpoint, `logs` table, Grafana log panels |
| **3** | Crash reporting | Catch + serialize crashes on iOS, new event type, Grafana alerts |
| **4** | Feature flags | `flags` table, `GET /v1/flags/:app_id`, cached on device with TTL |
| **5** | OTA config | Extend flags to arbitrary key-value config (model selection, API keys) |
| **6** | Revenue tracking | RevenueCat webhook → API → Postgres, revenue dashboards |
| **7** | Studio dashboard | Custom web UI replacing/supplementing Grafana for business ops |

## Non-Goals (for Phase 1)

- User authentication / accounts (no login, just API keys)
- Session replay
- A/B testing
- Push notifications
- Custom web dashboard (Grafana is sufficient)
- Real-time streaming / WebSockets
- Data warehouse export
