---
name: lanes-plan
description: Propose tmux lane allocations for pending work. Status view + assignment plan + sequencing logic.
---

# Lanes Plan

Read the current workspace state and the work queue, then propose how to allocate lanes.

## Process

### 1. Get current state

Run a lanes status view first (see [lanes-status](../lanes-status/SKILL.md)). You need to know what's available before you can plan.

### 2. Read the work queue

Check for pending work items. Look at:
- The project's task list, active items, or session plan
- Any state files or roadmap docs that define what's next
- Recent conversation context for work that's been discussed but not started

### 3. Propose assignments

For straightforward allocations, a per-pane list:

```
Pane: 0 (left)
Assignment: Meta (us)
Work: Orchestration, review, decisions
────────────────────────────────────────
Pane: 1 (upper-right)
Assignment: Coding Agent A
Work: Auth middleware + tests (item 1)
────────────────────────────────────────
Pane: 2 (lower-right)
Assignment: Coding Agent B
Work: API handlers for items 2-4
```

For complex layouts with dependencies, a spatial view:

```
┌─────────────────────────────┬─────────────────────────────┐
│                             │                             │
│   META (me)                 │   AGENT A                   │
│   Upper Left                │   Upper Right               │
│                             │                             │
│   Coordination, reviews,    │   Auth middleware + tests    │
│   architecture decisions    │   (item 1, the complex one) │
│                             │                             │
│   Always present.           │   Long-lived. Spin up now,  │
│   Light context.            │   independent, no blockers. │
│                             │                             │
├─────────────────────────────┼─────────────────────────────┤
│                             │                             │
│   AGENT B                   │   FLEX                      │
│   Lower Left                │   Lower Right               │
│                             │                             │
│   API handlers for items    │   Available for:            │
│   2-4 (same pattern)        │   - Code reviews as PRs     │
│                             │     come in                 │
│   Depends on A's middleware │   - Ad hoc investigation    │
│   landing first.            │                             │
│                             │   Spin up when needed,      │
│                             │   idle otherwise.           │
│                             │                             │
└─────────────────────────────┴─────────────────────────────┘
```

### 4. Sequencing logic

After the layout, explain the sequencing:
- What spins up now (independent, no blockers)
- What waits and for what (dependencies between lanes)
- What's held in reserve (flex panes, reviews)
- The critical path through the work

### 5. Present for review

The operator makes the final call. This is a proposal, not an execution plan. Include:
- Which harness is appropriate for each lane
- Whether to start fresh sessions or continue existing ones
- Any stale panes that should be recycled first

## Important

- Always run status first. Don't propose allocations against stale information.
- Match work to lanes, not lanes to work. If you have three items and two panes, batch the smaller items, don't spin up more panes.
- Name the critical path explicitly. The operator needs to know what's blocking what.
- Use the spatial view when the layout matters (dependencies, sequencing). Use the simple list when it's straightforward.
