---
name: lanes-status
description: Show the current state of all tmux lanes. Fast, visual, no ceremony.
---

# Lanes Status

Quick view of every pane in the current tmux window: what's running, what's idle, what's ready.

## Process

### 1. Probe the workspace

Run these three commands to gather the raw state:

```bash
# Inventory: index, size, process, PID
tmux list-panes -F '#{pane_index} #{pane_width}x#{pane_height} #{pane_current_command} #{pane_pid}'

# Titles
tmux list-panes -F '#{pane_index} #{pane_title}'

# Last few lines of each pane's output
for i in $(tmux list-panes -F '#{pane_index}'); do
  echo "=== Pane $i ==="
  tmux capture-pane -t "$i" -p | tail -8
done
```

### 2. Classify each pane

From the captured output, determine state:

| Signal | State |
|---|---|
| Agent UI visible, recent output | **Active** — agent is working |
| Agent UI visible, waiting for input | **Idle** — session open, no activity |
| Shell prompt at the bottom | **Shell** — ready for new agent |
| Anything else | **Unknown** — investigate |

### 3. Render the table

Present a single table showing the full workspace at a glance:

```
┌─────────────────┬────────┬──────────────────────┬──────────────────────────────────────────┐
│      Pane       │  Size  │        Title         │                 Status                   │
├─────────────────┼────────┼──────────────────────┼──────────────────────────────────────────┤
│ 0 (left)        │ 162x82 │ "meta"               │ Us — meta, active                        │
├─────────────────┼────────┼──────────────────────┼──────────────────────────────────────────┤
│ 1 (upper-right) │ 153x40 │ "Feature work"       │ Stale — last session's agent, idle       │
├─────────────────┼────────┼──────────────────────┼──────────────────────────────────────────┤
│ 2 (lower-right) │ 153x41 │ "Research"           │ Shell — ready for new agent              │
└─────────────────┴────────┴──────────────────────┴──────────────────────────────────────────┘
```

Include position hints (left, upper-right, etc.) when the layout is clear from pane sizes.

When the spatial layout matters, also render an ASCII view of the physical workspace:

```
┌─────────────────────────────┬─────────────────────────────┐
│                             │                             │
│   0: META (us)              │   1: Feature work           │
│   162x82 — active           │   153x40 — stale/idle       │
│                             │                             │
│                             ├─────────────────────────────┤
│                             │                             │
│                             │   2: Research               │
│                             │   153x41 — shell, ready     │
│                             │                             │
└─────────────────────────────┴─────────────────────────────┘
```

This gives the operator an at-a-glance map of what's where.

## Important

- This is a snapshot, not a dashboard. Run it when you need to see the board.
- If a pane's state is ambiguous, say so. Don't guess.
- Keep the output tight. The value is in the glance.
