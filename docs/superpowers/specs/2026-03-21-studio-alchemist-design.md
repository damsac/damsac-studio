# Studio Alchemist: The damsac-studio Meta-Agent

## Overview

The studio alchemist is a persistent Claude Code session running on the VPS that serves as the top-level meta-agent for all damsac work. It holds strategic context across projects (studio, Murmur, SDK), delegates implementation to workers, and curates the team's shared understanding of what matters.

**Discord is its human interface.** Tmux + Mercury is its agent interface. The studio CLI + SQLite is its structured state. Memory.md is its persistent brain.

This spec replaces the "Cron: Daily Curation" section of the studio agent design. Instead of a batch job that runs on a timer, the alchemist is always-on — listening to Discord, reading Mercury, and curating continuously.

**Core principle from metacraft:** Separate strategic context from execution. The alchemist never touches code. It reads the landscape, names what matters, and delegates downward.

## Architecture

```
                    Discord (gudnuf + isaac)
                         ↕
                Claude Code channels plugin
                         ↕
┌────────────────────────────────────────────────────────────┐
│                    VPS (NixOS)                              │
│                                                             │
│  tmux: pane 0 ─────────────────────────────────────────     │
│  ┌───────────────────────────────────────────────────┐      │
│  │  ALCHEMIST (claude --channels discord)             │      │
│  │  identity: alchemist                                │      │
│  │  reads: Mercury, VCS log, studio CLI, memory.md    │      │
│  │  writes: memory.md, dashboard.json, studio items   │      │
│  │  delegates: drafts prompts → workers via Mercury   │      │
│  └───────────────────────────────────────────────────┘      │
│       ↕ Mercury                                             │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐                  │
│  │ gudnuf   │  │ isaac    │  │ workers  │                  │
│  │ workspace│  │ workspace│  │ (spawned)│                  │
│  └──────────┘  └──────────┘  └──────────┘                  │
│       ↕              ↕            ↕                         │
│  /srv/damsac/ ─── shared repo ──────────────────           │
│       ↕                                                     │
│  ┌─────────┐   ┌────────┐   ┌────────────────┐            │
│  │ Go API  │   │ SQLite │   │ Files          │            │
│  │ /dash   │──▶│ items  │   │ memory.md      │            │
│  │ /v1/*   │──▶│activity│   │ dashboard.json │            │
│  └─────────┘   └────────┘   └────────────────┘            │
└────────────────────────────────────────────────────────────┘
```

## Layers

Each layer does one thing. No layer tries to do another layer's job.

| Layer | What it does | Persistence |
|-------|-------------|-------------|
| **Discord** | Human conversation — brainstorming, questions, decisions | Discord history (external) |
| **Alchemist session** | Strategic context, delegation, curation | memory.md, dashboard.json, studio DB |
| **Mercury** | Agent-to-agent communication | mercury.db (SQLite, `~/.local/share/mercury/`) |
| **Studio CLI/DB** | Structured project state — items, activity log | studio.db (SQLite, `$DATA_DIR/`) |
| **VCS (jj/git)** | Code truth — what actually shipped | `/srv/damsac/` workspaces |
| **Web dashboard** | Read-only curated status view | Reads dashboard.json + live DB |

> **Note on VCS:** The VPS currently uses jj (Jujutsu) with colocated git repos and per-user workspaces. The forge and agent specs were written before the jj migration and still reference git. Commands in this spec use whichever VCS is active (`jj log` or `git log`).

## Identity & Role

The alchemist follows the metacraft philosophy:

**Does:**
- Hold strategic context across all damsac projects
- Read the landscape: Mercury channels, VCS log, analytics, Discord history
- Curate the dashboard — write the daily brief, organize sections, set emphasis
- Manage items via studio CLI — create, prioritize, tag, archive
- Delegate implementation — draft clear prompts with acceptance criteria, dispatch to workers
- Maintain memory.md — update when it learns something important
- Answer questions from Discord — "@studio what's blocking Murmur launch?"
- Triage — when a friction or idea surfaces in Discord, decide: item? delegate? park?

**Does not:**
- Write code, edit files, run builds, debug errors
- Descend into implementation detail — the moment it starts touching source files, it has abandoned the post
- Hold stale context — if memory.md hasn't been updated, that's the first priority

**Mercury identity:** `alchemist` (plain — there's one alchemist for the damsac practice, matching the Mercury naming convention)

On session start:
```bash
mercury subscribe --as alchemist --channel status
mercury subscribe --as alchemist --channel studio
mercury send --as alchemist --to status "alchemist online, reading state"
```

## Discord Integration

### Setup

Discord bot created at discord.com/developers/applications:
- Message Content Intent enabled
- Permissions: View Channels, Send Messages, Read Message History, Attach Files
- Added to the damsac Discord server

Claude Code channels plugin installed on VPS:
```bash
/plugin install discord@claude-plugins-official
/discord:configure <bot_token>
```

Bot token stored on disk and read by the plugin at startup. Exact path TBD — needs to survive reboots (unlike `/run/` which is tmpfs on NixOS). Options: a persistent path like `/var/lib/damsac-studio/discord-bot-token`, or a secrets manager (agenix/sops-nix). For now, manual file creation is fine — same bootstrap pattern as the dashboard password.

### Behavior

- **Responds on @mention** — doesn't inject itself into conversations uninvited
- **Has full channel history access** — when asked "go read what we discussed about X", it can pull Discord history for context
- **Allowlist gated** — only gudnuf and isaac can trigger responses (pairing flow + `/discord:access policy allowlist`)

### What Discord is good for (and not)

**Use Discord for:** brainstorming, quick questions, status checks, asking the alchemist to do something ("create an item for that"), sharing context ("here's what we decided in the meeting")

**Don't use Discord for:** structured project state (that's studio items), code discussion (that's jj/PR comments), detailed implementation plans (that's docs/specs)

When a Discord conversation produces a decision or action item, the alchemist captures it in the appropriate system — creates a studio item, updates memory.md, or drafts a spec.

## Session Lifecycle

### Startup

The alchemist runs in tmux pane 0 of the shared session:

```bash
claude --channels plugin:discord@claude-plugins-official
```

On start, it reads (in order):
1. `memory.md` — persistent strategic context (same file referenced in the studio agent spec, at `$DATA_DIR/memory.md`)
2. `mercury read --as alchemist` — what happened while it was away
3. `studio list` — current items
4. VCS log (`jj log` or `git log`, last ~20 commits) — recent code changes

Then posts to Mercury: `alchemist online, current state: <brief summary>`

### During

- Responds to Discord @mentions (this is the primary trigger for all activity)
- Reads Mercury when prompted or as part of handling a Discord request (no background polling — Claude Code sessions don't have a built-in loop, so Mercury reads happen when the alchemist is already active)
- Curates dashboard when asked ("@studio update the dashboard") or as a natural part of answering a status question
- Updates memory.md when it learns something important

### Rekindle (context refresh)

When the context window gets heavy, use the rekindle pattern:
1. Gather: write everything important to memory.md
2. Post to Mercury: `alchemist rekindling, state persisted`
3. End session
4. Start fresh session in same pane
5. Re-orient from memory.md, Mercury

This is manual for now. The alchemist can recognize when it needs to rekindle ("my context is getting long, I should gather and restart").

## Worker Delegation

When something needs to be built, the alchemist:

1. Creates a studio item: `studio add "implement items table in store.go" --project studio --priority 2`
2. Drafts a scoped prompt with:
   - What to build (specific, bounded)
   - Acceptance criteria (what "done" looks like)
   - Files to read first
   - Constraints (follow CLAUDE.md conventions, don't change unrelated code)
3. Dispatches via Mercury: `mercury send --as alchemist --to workers "<prompt>"`
4. Or via relay to a specific tmux pane if a worker is already running

Workers report back via Mercury when done. The alchemist verifies (reads the diff, checks VCS log) and updates the item.

**Worker spawning in v1 is manual.** The alchemist says what needs to happen (via Discord or Mercury), and a human starts a Claude Code session in a new tmux pane. Automated spawning is a future enhancement.

## Curation

The alchemist replaces the cron-based curator from the original studio agent spec. Instead of running on a timer, it curates when asked:

- A human asks ("@studio update the dashboard", "@studio what's the status")
- As a natural side effect of answering a question that requires reading current state

Curation means:
1. Read current state (studio list, VCS log, Mercury, analytics via MCP)
2. Write/update the daily brief in dashboard.json
3. Reorganize sections if project priorities shifted
4. Create/update/archive items based on what it observes
5. Update memory.md with new learnings

## Input Sources

What the alchemist watches to maintain the strategic view:

| Source | How | What it reveals |
|--------|-----|----------------|
| Discord | Channel plugin (real-time on @mention, history on demand) | Human decisions, brainstorms, priorities |
| Mercury | `mercury read --as alchemist` (on demand, during active handling) | What other Claude sessions are doing |
| VCS log | `jj log` / `git log` (on demand) | What actually shipped |
| Studio items | `studio list` / `studio show` | Structured project state |
| Analytics | MCP query tool (`SELECT` on events table) | What users are doing in Murmur |
| Memory.md | Direct file read | Accumulated strategic context |

Future sources (not in v1):
- Meeting transcripts (uploaded to Discord or a shared directory)
- Discord voice/video channel integration
- GitHub notifications

## NixOS Integration

### Discord bot token

Stored at a persistent path (e.g. `/var/lib/damsac-studio/discord-bot-token`). The Claude Code channels plugin reads the token from its own config (set via `/discord:configure`), so no NixOS module changes needed for v1. Proper secrets management (agenix/sops-nix) is a future improvement.

### Alchemist tmux pane

The alchemist pane is not managed by systemd — it's a tmux session that gets started manually or via a helper script. This is intentional: the alchemist is interactive (you can attach and watch it work), and it needs the Claude Code channels plugin which requires an interactive session.

Helper script for starting/restarting:

```bash
# /srv/damsac/start-alchemist.sh
#!/usr/bin/env bash
tmux new-window -t pair -n alchemist \
  'claude --channels plugin:discord@claude-plugins-official'
```

### Mercury

Already being added to flake.nix + home.nix declaratively. Both users and the alchemist session have access to the `mercury` binary.

## Relationship to Other Specs

- **Studio Agent Design** (`studio-agent-design.md`) — The data model, CLI, API endpoints, dashboard, and Murmur integration are unchanged. This spec replaces only the "Cron: Daily Curation" section with the always-on alchemist.
- **Studio Forge** (`studio-forge-design.md`) — The VPS setup, user accounts, tmux infrastructure, and workspaces are the environment the alchemist runs in. The forge spec still references git; the VPS has since migrated to jj (colocated).

## What's Not in v1

- Proactive curation (alchemist acts only when @mentioned or when a human is in the tmux session — no background autonomy yet)
- Voice/video channel integration
- Meeting transcript ingestion
- Custom Discord slash commands (use @mention for everything initially)
- Multiple alchemists for different projects (one alchemist covers all damsac work)
- Automated rekindle (manual gather + restart for now)
