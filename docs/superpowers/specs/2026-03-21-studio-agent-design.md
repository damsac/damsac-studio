# Studio Agent: Project Management for damsac-studio

## Overview

An agentic project management system built into damsac-studio. A `studio` CLI lets Claude Code instances (running on the VPS via cron) manage project items, maintain memory, and curate a dashboard that humans open to see what matters. Murmur integrates bidirectionally — studio items flow into Murmur as entries, and updates in Murmur sync back.

**Core principle:** Humans read the dashboard. Agents use the CLI. The intelligence lives in Claude Code, not in the Go binary.

## Architecture

```
┌─────────────┐     ┌──────────────────────────────────────────┐
│   Murmur    │     │              VPS (NixOS)                 │
│  (iOS app)  │◄───►│                                          │
│             │     │  ┌─────────┐   ┌────────┐   ┌────────┐  │
│ Studio items│     │  │ Go API  │   │ SQLite │   │ Files  │  │
│ appear as   │     │  │         │   │        │   │        │  │
│ entries     │     │  │ /dash   │──►│ items  │   │memory  │  │
│ (source:    │     │  │ /v1/items│──►│ activity│   │.md     │  │
│  studio)    │     │  │ /v1/evts│──►│ events │   │dash    │  │
│             │     │  └────┬────┘   └────────┘   │.json   │  │
└─────────────┘     │       │                      └───┬────┘  │
                    │  ┌────┴────────────────────┐     │       │
                    │  │    studio CLI            │     │       │
                    │  │  (same Go binary)        │─────┘       │
                    │  └────┬────────────────────┘             │
                    │       │                                   │
                    │  ┌────┴────────────────────┐             │
                    │  │  Claude Code (cron)      │             │
                    │  │  - reads memory.md       │             │
                    │  │  - runs studio list/add  │             │
                    │  │  - writes dashboard.json │             │
                    │  │  - writes memory.md      │             │
                    │  └──────────────────────────┘             │
                    └──────────────────────────────────────────┘
```

## Data Model

### SQLite: `items` table

| Column | Type | Purpose |
|--------|------|---------|
| `id` | TEXT PK | 8-character lowercase hex string via `crypto/rand` (e.g. `abc12def`) |
| `content` | TEXT NOT NULL | The item — "fix SSE bug", "should we switch to Postgres?" |
| `tags` | TEXT DEFAULT '[]' | JSON array, agent-assigned organically |
| `status` | TEXT DEFAULT 'active' | `active`, `done`, `archived` |
| `author` | TEXT | Who created it (`gudnuf`, `isaac`, `claude`) |
| `project` | TEXT | Optional grouping (`murmur`, `studio`, `sdk`) |
| `priority` | INTEGER | 1-5, nullable |
| `notes` | TEXT DEFAULT '' | Freeform text field. The activity_log provides the structured audit trail; notes is for unstructured context the agent or humans want attached to the item. |
| `created_at` | TEXT NOT NULL | RFC3339 |
| `updated_at` | TEXT NOT NULL | RFC3339 |
| `completed_at` | TEXT | RFC3339, nullable |

No fixed category/type system. Tags are freeform and evolve organically as the agent learns what groupings matter.

**Indexes:**
- `CREATE INDEX idx_items_status ON items (status)`
- `CREATE INDEX idx_items_project ON items (project, status)`

Tag filtering uses `EXISTS (SELECT 1 FROM json_each(items.tags) WHERE json_each.value = ?)` for exact matching. The table is expected to stay small (hundreds of items), so no special index for tags.

### SQLite: `activity_log` table

| Column | Type | Purpose |
|--------|------|---------|
| `id` | INTEGER PK | Auto-increment |
| `item_id` | TEXT | FK to items(id), nullable (some actions are global) |
| `action` | TEXT NOT NULL | `created`, `updated`, `completed`, `archived`, `curated` |
| `actor` | TEXT | Who did it (`gudnuf`, `isaac`, `claude`, `murmur`) |
| `detail` | TEXT | Human-readable description |
| `created_at` | TEXT NOT NULL | RFC3339 |

### File: `$DATA_DIR/memory.md`

One bounded markdown file. Claude Code reads and rewrites it directly using its own file tools. No CLI wrapper — the agent manages structure however it wants (headers, sections, bullets). Bounded by agent prompt convention (e.g. "keep under 1000 words").

### File: `$DATA_DIR/dashboard.json`

The curated dashboard composition. Written by Claude Code during curation. Contains:

```json
{
  "version": 1,
  "brief": "SSE bug is the last blocker for TestFlight.",
  "date": "2026-03-21",
  "composition": {
    "sections": [
      {
        "id": "s1",
        "title": "murmur",
        "items": ["abc123", "def456"]
      }
    ],
    "emphasis": {
      "abc123": "urgent"
    }
  }
}
```

The dashboard reads **live item data from SQLite** (status, content, tags, priority) but uses `dashboard.json` for the **curated presentation** — which items are highlighted, how they're grouped, and the narrative brief. This means the dashboard is always fresh on item state, but the editorial framing updates when Claude Code curates.

Composition updates use a diff model inspired by Murmur's layout system — Claude Code reads the current `dashboard.json`, applies incremental changes (add section, remove entry, change emphasis), and writes it back. No wholesale regeneration unless needed.

## CLI: `studio`

The Go binary operates in two modes based on its first argument:
- No args or unrecognized first arg → starts HTTP server
- Recognized subcommand (`add`, `list`, `show`, `update`, `archive`, `log`) → runs CLI mode

### Commands

```bash
# Items
studio add "fix SSE reconnection bug"              # create item
studio add "switch to Postgres?" --project murmur   # with project
studio list                                         # active items
studio list --project murmur                        # filter by project
studio list --tag blocker                           # filter by tag
studio list --done                                  # completed items
studio show <id>                                    # detail view + notes + activity
studio update <id> --done                           # mark complete
studio update <id> --tag blocker                    # add tag
studio update <id> --priority 1                     # set priority
studio update <id> --note "tried X, didn't work"    # append note
studio update <id> --project murmur                 # set project
studio archive <id>                                 # archive item

# Activity
studio log                                          # recent activity
studio log <id>                                     # activity for specific item
```

IDs are 8 hex chars, always displayed in full. On the command line, a prefix of 6+ chars is accepted and resolved. If a prefix matches multiple items, the CLI prints an error listing the matches (same pattern as git short hashes). Output is plain text, agent-friendly.

**Memory and dashboard.json are not managed by the CLI** — Claude Code uses its own Read/Write tools for those files directly.

## API Endpoints (new)

Added alongside existing `/v1/events` and `/dashboard`:

| Method | Endpoint | Auth | Purpose |
|--------|----------|------|---------|
| `GET` | `/v1/items` | API key | List items (filters: status, project, tag) |
| `POST` | `/v1/items` | API key | Create item |
| `PATCH` | `/v1/items/:id` | API key | Update item (status, tags, notes, priority) |
| `GET` | `/v1/items/:id` | API key | Get single item with activity |

Same `X-API-Key` auth as event ingest. Item endpoints are not scoped by `app_id` — any valid API key grants full read/write access to all items. This is intentional for a team-internal tool. The `actor` field in activity logs is derived from the authenticated `app_id` for API requests, or provided explicitly by the CLI.

## Dashboard

Replaces the current `/projects` GitHub board page at the same route (`/projects`). The existing `/dashboard` analytics event viewer remains unchanged.

### Layout: Hybrid (brief + project groups)

1. **Daily brief** — narrative summary at top, written by Claude Code during curation
2. **Stats bar** — live counts from SQLite (blockers, active, done this week)
3. **Project sections** — items grouped by project, ordered by composition. Each item shows content, status indicator, priority badge, tags
4. **Recently done** — collapsed section at bottom

**Data flow:**
- Brief and composition (grouping, emphasis) come from `dashboard.json`
- Item data (content, status, tags) comes live from SQLite
- Page is server-rendered (Go templates + HTMX, matching existing dashboard style)
- Fresh on each page load — no SSE needed for this view

## Murmur Integration

### Studio → Murmur

Murmur calls `GET /v1/items` on app launch (or periodically) to fetch active studio items. These become Murmur entries with:

- `source: .studio` (new `EntrySource` case)
- Category auto-assigned by Murmur's agent (a blocker becomes a todo, a question stays a question)
- Content and notes mapped from studio item fields
- Short ID preserved for sync

Studio items appear in Murmur's smart list alongside personal entries. Murmur's existing sort logic (overdue → due today → priority → recency) handles ordering. The agent sees them in context and can reference them naturally ("the SSE bug from studio").

### Murmur → Studio

When a studio-sourced entry is updated in Murmur (completed, notes added, priority changed), Murmur calls `PATCH /v1/items/:id` to sync the change back.

### Sync model

- **Pull-based:** Murmur fetches on launch + periodic refresh (not push/webhook)
- **Conflict resolution:** Last-write-wins (no optimistic concurrency for v1). In practice, conflicts are rare — the team is small and items change infrequently. If this becomes a problem, add `updated_at` checks to PATCH later.
- **Scope:** Only active items sync to Murmur. Done/archived items don't flow.
- **Private feature:** The Murmur-studio sync is for the damsac team. The API endpoints are general-purpose, but the Murmur integration is team-specific (requires API key configured in the app).

## Cron: Daily Curation

> **Superseded:** See `studio-alchemist-design.md`. The curation role is now handled by a persistent alchemist session with Discord as its human interface, not a cron job.

A Claude Code session runs on cron (e.g. daily at 8am, or multiple times per day):

1. Reads `$DATA_DIR/memory.md` for persistent context
2. Runs `studio list`, `studio log` to get current state
3. Optionally checks git log, GitHub activity, analytics events for additional context
4. Writes the daily brief and updates `dashboard.json` composition (diff-based)
5. May create/update/archive items based on what it observes
6. Updates `memory.md` with new learnings

The cron job is a standard Claude Code invocation with a prompt like: "You are the studio curator. Review the current project state and update the dashboard for the team."

## Implementation Notes

### Go binary dual-mode

```go
func main() {
    if len(os.Args) > 1 && isStudioCommand(os.Args[1]) {
        runCLI(os.Args[1:])
    } else {
        runServer()
    }
}
```

Use subcommand detection, not symlink/`os.Args[0]` detection. The Nix package renames the binary to `damsac-studio`, and a symlink `studio → damsac-studio` is added for convenience, but routing is based on the first argument.

### Cross-process database concurrency

The CLI and HTTP server are separate OS processes sharing the same SQLite file. SQLite WAL mode with `busy_timeout=5000` (already configured) handles this safely — no data corruption risk. The CLI must use the same pragma configuration as the server (particularly `journal_mode=WAL` and `busy_timeout=5000`). Do not use connection pooling in CLI mode — single connection is sufficient.

### Cron operational notes

- Use `flock` to prevent overlapping cron runs
- Target session duration: under 2 minutes
- Model: use the cheapest model that produces good curation (Haiku or Sonnet)
- Frequency: start with once daily, increase if needed

### Existing code impact

- `store.go` — add `items` and `activity_log` tables to `migrate()`, add query methods
- `main.go` — add item API handlers, CLI routing
- `dashboard.go` — replace `HandleProjects` with new curated dashboard handler
- `templates/projects.html` — replace with new dashboard template
- New files: `cli.go` (CLI commands), `items.go` (item handler + API)

### NixOS integration

- Symlink `studio` → API binary in the Nix package
- Add `$DATA_DIR/memory.md` and `$DATA_DIR/dashboard.json` to data directory
- Cron job added to NixOS config (systemd timer invoking Claude Code)
