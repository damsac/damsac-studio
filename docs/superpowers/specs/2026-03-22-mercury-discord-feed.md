# Mercury Discord Live Feed

## Summary

A lightweight service that mirrors all Mercury inter-agent messages into a dedicated Discord channel in real-time. Humans can watch agent coordination from Discord without SSH-ing into the VPS.

## Motivation

Mercury is the inter-agent messaging bus — agents post status updates, coordinate work, and route feedback through Mercury channels. Right now, the only way to watch this traffic is to SSH into the VPS and run `mercury listen` or query the SQLite DB directly. This is friction that discourages casual observation.

Discord is where humans already are. Piping Mercury messages into a Discord channel gives humans a live, passive view of what agents are doing — no terminal required. It also creates a searchable archive of agent coordination history via Discord's native search.

## Architecture

```
Mercury SQLite DB (read-only)
        │
        │  poll every 2s
        ▼
┌─────────────────────┐
│  mercury-discord-feed│       discord.js
│  (bun/TypeScript)   │──────────────────▶  Discord Channel
│                     │    POST embeds
└─────────────────────┘
        │
        │  persist cursor
        ▼
   cursor file (~/.local/share/mercury/discord-feed-cursor)
```

### Why a separate service (not embedded)

- Mercury is a CLI tool with a SQLite DB, not a long-running server with an HTTP API
- The feed service has its own lifecycle (can crash/restart independently)
- Different runtime (bun/TypeScript) from the Go API — keeps concerns separate
- No changes needed to Mercury itself

### Why polling (not SQLite triggers or WAL tail)

- Polling is dead simple and reliable — no inotify edge cases, no SQLite extension dependencies
- 2-second poll interval is fast enough for human observation (sub-second latency is unnecessary)
- Mercury's message volume is low (tens of messages per hour at peak) — polling is negligible load
- The read-only SQLite connection coexists cleanly with Mercury's write connection via WAL mode

## Data flow

### Mercury DB schema (relevant tables)

```sql
CREATE TABLE messages (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  channel TEXT NOT NULL,
  sender TEXT NOT NULL,
  body TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Indexes: idx_messages_channel (channel), idx_messages_created (created_at)
```

### Poll query

```sql
SELECT id, channel, sender, body, created_at
FROM messages
WHERE id > ?
ORDER BY id ASC
LIMIT 50;
```

The `?` parameter is the last-seen message ID from the cursor file. `LIMIT 50` caps each poll batch to avoid flooding Discord if the service starts with a large backlog.

### Cursor persistence

A plain text file at `~/.local/share/mercury/discord-feed-cursor` containing a single integer: the last successfully posted message ID.

- Read on startup (default to 0 if missing — will replay all history)
- Written after each successful Discord post
- Atomic write (write to `.tmp`, rename) to avoid corruption on crash

On first run with an existing Mercury DB, the service will replay all historical messages. To skip history and start from "now", manually write the current max ID to the cursor file before starting.

## Discord message format

Each Mercury message becomes a Discord embed for visual structure:

```
┌─────────────────────────────────────────┐
│  🔵 #studio                             │  <- embed title: channel name
│                                         │
│  oracle                                 │  <- author field: sender
│  Starting code review for PR #42        │  <- description: body
│                                         │
│  2026-03-22 10:27:49 UTC                │  <- footer: timestamp
└─────────────────────────────────────────┘
```

### Embed construction

```typescript
{
  color: channelColor(msg.channel),  // deterministic color per channel
  title: `#${msg.channel}`,
  description: msg.body,
  author: { name: msg.sender },
  footer: { text: formatTimestamp(msg.created_at) },
}
```

### Channel colors

Deterministic color assignment based on channel name hash, so each Mercury channel gets a visually distinct embed color. Known channels at time of writing:

| Mercury Channel   | Suggested Color |
|-------------------|----------------|
| status            | `#808080` (gray) |
| studio            | `#5865F2` (blurple) |
| workers           | `#57F287` (green) |
| keeper:feedback   | `#FEE75C` (yellow) |
| keeper:murmur     | `#EB459E` (pink) |
| test              | `#95A5A6` (light gray) |

New/unknown channels fall back to a hash-derived color.

### Long messages

Mercury messages can be long (agent bootstrap prompts, detailed feedback). Discord embed descriptions cap at 4096 characters. If `body` exceeds 4000 characters:

1. Truncate to 4000 characters
2. Append `\n\n... (truncated, ${original_length} chars total)`

## Configuration

All configuration via environment variables:

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `DISCORD_BOT_TOKEN` | yes | — | Discord bot token (same bot as Claude Code's Discord channel) |
| `DISCORD_FEED_CHANNEL_ID` | yes | — | Discord channel ID to post messages to |
| `MERCURY_DB_PATH` | no | `~/.local/share/mercury/mercury.db` | Path to Mercury SQLite database |
| `CURSOR_FILE_PATH` | no | `~/.local/share/mercury/discord-feed-cursor` | Path to cursor persistence file |
| `POLL_INTERVAL_MS` | no | `2000` | Poll interval in milliseconds |
| `BATCH_LIMIT` | no | `50` | Max messages per poll cycle |

The Discord bot token lives at `~/.claude/channels/discord/.env` (as `DISCORD_BOT_TOKEN`). The service can source this file directly or the systemd unit can reference it via `EnvironmentFile`.

## Implementation

### File structure

```
tools/mercury-discord-feed/
├── index.ts          # Entry point: setup, poll loop, graceful shutdown
├── mercury.ts        # SQLite reader: open DB, poll query, cursor management
├── discord.ts        # Discord client: connect, post embeds, rate limit handling
├── format.ts         # Message formatting: embeds, colors, truncation
├── package.json
├── tsconfig.json
└── bun.lock
```

### Dependencies

- `discord.js` — Discord API client (handles websocket, rate limits, reconnection)
- `better-sqlite3` — Synchronous SQLite for bun (read-only mode via `readonly: true`)

No other runtime dependencies. `better-sqlite3` is synchronous which is fine for a polling loop — the read is <1ms for a `WHERE id > ? LIMIT 50` query on an indexed column.

### Entry point (`index.ts`)

```typescript
// Pseudocode — not final implementation

const db = openMercuryDB(config.mercuryDbPath);
const cursor = loadCursor(config.cursorFilePath);
const discord = await connectDiscord(config.botToken);
const channel = await discord.channels.fetch(config.feedChannelId);

// Poll loop
const interval = setInterval(async () => {
  const messages = db.pollNewMessages(cursor.lastId, config.batchLimit);
  for (const msg of messages) {
    await channel.send({ embeds: [formatEmbed(msg)] });
    cursor.update(msg.id);
  }
  cursor.persist();
}, config.pollIntervalMs);

// Graceful shutdown
process.on("SIGTERM", () => {
  clearInterval(interval);
  cursor.persist();
  discord.destroy();
  db.close();
  process.exit(0);
});
```

### Rate limiting

Discord rate limits: 5 messages per 5 seconds per channel. `discord.js` handles rate limiting internally (queues and retries). For burst scenarios (replaying history), the library's built-in queue prevents 429 errors.

If the backlog exceeds ~100 messages on startup, consider posting a summary message instead:

```
📋 Catching up: skipped N historical messages. Showing messages from [timestamp] onward.
```

This is an optional enhancement — the basic implementation can just let discord.js queue them.

### Error handling

- **Mercury DB not found:** Log error and retry every 10 seconds (Mercury may not have been initialized yet)
- **Mercury DB locked:** Won't happen — read-only connection with WAL mode supports concurrent reads
- **Discord connection lost:** `discord.js` auto-reconnects. Messages that fail to send during disconnection are lost (acceptable — they'll still be in Mercury DB for later review)
- **Cursor file write failure:** Log warning but continue. On restart, some messages may be re-posted (duplicate but not lost)

### Startup message

On connect, post a startup message to the feed channel:

```
🟢 Mercury feed online — watching all channels
```

On graceful shutdown:

```
🔴 Mercury feed offline
```

## NixOS integration

### Option 1: systemd service (recommended)

```nix
# In module.nix or a new mercury-discord-feed.nix module
systemd.services.mercury-discord-feed = {
  description = "Mercury to Discord live feed";
  wantedBy = [ "multi-user.target" ];
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];

  serviceConfig = {
    Type = "simple";
    ExecStart = "${pkgs.bun}/bin/bun run /srv/damsac/damsac-studio/tools/mercury-discord-feed/index.ts";
    Restart = "always";
    RestartSec = 5;
    User = "gudnuf";  # or a dedicated service user
    EnvironmentFile = [
      "/home/gudnuf/.claude/channels/discord/.env"
    ];
    Environment = [
      "DISCORD_FEED_CHANNEL_ID=FILL_IN"
      "MERCURY_DB_PATH=/home/gudnuf/.local/share/mercury/mercury.db"
    ];
  };
};
```

### Option 2: tmux pane

For development, run in a tmux pane alongside other services:

```bash
cd /srv/damsac/damsac-studio/tools/mercury-discord-feed
source ~/.claude/channels/discord/.env
export DISCORD_FEED_CHANNEL_ID="..."
bun run index.ts
```

### Recommendation

Start with Option 2 (tmux pane) during development, graduate to Option 1 (systemd) once stable. The systemd service gives auto-restart, log integration (`journalctl -u mercury-discord-feed`), and clean lifecycle management.

## Deduplication

The cursor-based approach inherently prevents duplicates in the normal case — each message ID is monotonically increasing and only posted once. Edge cases:

| Scenario | Behavior |
|----------|----------|
| Clean restart | Cursor file preserved, resumes from last posted ID |
| Crash mid-batch | Some messages may be re-posted (cursor not yet persisted). Discord shows duplicates but no data loss. |
| Cursor file deleted | Replays all history from ID 0. Mostly annoying, not harmful. |
| Multiple feed instances | Would cause duplicates. Only run one instance. Not worth adding distributed locking for v1. |

## Scope and non-goals

### v1 scope

- Read-only: Mercury to Discord only
- All Mercury channels posted to one Discord channel
- Polling-based with cursor persistence
- Formatted embeds with channel colors
- Graceful shutdown with cursor save
- Runs as systemd service or tmux pane

### Non-goals (future enhancements)

- **Bidirectional (Discord to Mercury):** Humans posting in Discord channel gets injected into Mercury. Requires careful design around sender identity and channel routing.
- **Channel filtering:** Subscribe to specific Mercury channels only. Easy to add but unnecessary when message volume is low.
- **Per-channel Discord channels:** Route each Mercury channel to a separate Discord channel. Adds configuration complexity for marginal benefit.
- **Discord slash commands:** `/mercury send #studio "message"` — interactive Mercury posting from Discord.
- **Rich formatting:** Parsing message bodies for code blocks, links, mentions. v1 posts raw text.
- **Webhook-based posting:** Using Discord webhooks instead of bot messages. Webhooks allow custom avatars per sender but add URL management overhead.
- **Backpressure/buffering:** Sophisticated buffering for high-volume scenarios. Mercury volume is low enough that this is unnecessary.

## Testing

### Manual testing checklist

1. Start the feed service with a fresh cursor (no cursor file)
2. Verify historical messages appear in Discord channel
3. Post a new Mercury message (`mercury send test "hello from test"`)
4. Verify it appears in Discord within ~2 seconds
5. Kill the service (SIGTERM) and restart
6. Verify no duplicate messages appear
7. Verify the startup/shutdown messages appear in Discord
8. Test with a very long message (>4000 chars) — verify truncation

### Automated tests

- `format.test.ts` — embed construction, color mapping, truncation
- `mercury.test.ts` — cursor read/write, poll query (using a test SQLite DB)
- No integration test against real Discord (manual testing covers this)

## Open questions

1. **Which Discord channel?** Need to create a `#mercury-feed` channel in the Discord server and note its ID.
2. **Bot permissions:** The existing bot needs "Send Messages" and "Embed Links" permissions in the feed channel. Verify these are granted.
3. **Cursor file location:** `~/.local/share/mercury/` is Mercury's data dir. Is it appropriate to put the feed cursor there, or should it live elsewhere (e.g. `~/.local/share/mercury-discord-feed/`)?
4. **User identity for systemd:** Should the service run as `gudnuf` (who owns the Mercury DB and Discord bot token) or a dedicated service user with read access to both?
