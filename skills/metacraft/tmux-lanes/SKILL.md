---
name: tmux-lanes
description: Manage a multi-agent tmux workspace. Status, allocation, prompt drafting, cleanup.
---

# Tmux Lanes

Manage a multi-agent workspace as a set of tmux panes, each one a lane with a known state, a known assignment, and a clean lifecycle.

## What this is

When you're running multiple AI agents in parallel, each in its own tmux pane, the workspace itself becomes an instrument that needs tuning. Which pane is active? Which is stale? Which is ready for new work? What's each one doing?

This skill turns the tmux window into a managed workspace: visible state, deliberate allocation, clean handoffs.

Executable sub-skills: [lanes-status](../lanes-status/SKILL.md) for a quick status view, [lanes-plan](../lanes-plan/SKILL.md) for allocation proposals.

## When to use it

- Any workflow where multiple agents run in parallel tmux panes
- When you've lost track of which pane is doing what
- Before allocating new work across lanes
- When stale sessions are cluttering the workspace

## The pattern

### Status view

Probe the workspace and present the full picture. Three commands give you everything:

```bash
# Inventory: index, size, process, PID
tmux list-panes -t <window> -F '#{pane_index} #{pane_width}x#{pane_height} #{pane_current_command} #{pane_pid}'

# Titles: what each pane is named
tmux list-panes -t <window> -F '#{pane_index} #{pane_title}'

# State: last few lines of each pane's output
for i in 0 1 2; do echo "=== Pane $i ===" && tmux capture-pane -t <window>.$i -p | tail -5; done
```

From the captured output, classify each pane:
- **Active**: an agent is running and producing output
- **Idle/Stale**: an agent session is open but waiting for input (e.g. INSERT mode with no recent activity)
- **Shell**: no agent running, clean prompt ready for work
- **Unknown**: something else is running

Render the result as a table:

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

The goal: one glance tells you the state of the whole workspace.

### Allocation

Read the work queue (task list, active items, session plan), count available lanes, and propose assignments:

```
Pane: 0 (left)
Assignment: Meta (us)
Work: Orchestration, review, decisions
────────────────────────────────────────
Pane: 1 (upper-right)
Assignment: Coding Agent A
Work: Implement auth middleware — tests + integration (item 1, the complex one)
────────────────────────────────────────
Pane: 2 (lower-right)
Assignment: Coding Agent B
Work: API endpoint handlers for items 2-4 (same pattern repeated)
```

For complex layouts, a spatial view helps the operator see the whole board:

```
┌─────────────────────────────┬─────────────────────────────┐
│                             │                             │
│   META (me)                 │   CODING AGENT A            │
│   Upper Left                │   Upper Right               │
│                             │                             │
│   Coordination, reviews,    │   Auth middleware + tests   │
│   architecture decisions    │   (item 1, the complex one) │
│                             │                             │
│   Always present.           │   Long-lived. Spin up now,  │
│   Light context.            │   independent, no blockers. │
│                             │                             │
├─────────────────────────────┼─────────────────────────────┤
│                             │                             │
│   CODING AGENT B            │   FLEX                      │
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

Sequencing logic:

- Upper Right (A): Spin up now. Independent, no blockers.
- Lower Left (B): Spin up after A's middleware lands. Same agent
  can continue or fresh session.
- Lower Right: Hold in reserve for reviews as A and B produce PRs.

Critical path: A middleware → B handlers → integration tests.
Everything else is parallel enrichment.
```

Consider:
- Which harness is appropriate (some tasks favor one tool over another)
- Whether a pane's existing context is useful for the new task
- Whether to start a fresh session or continue an existing one
- The operator makes the final call on assignments

### Prompt drafting

When a lane gets an assignment, draft a deployment prompt:

- Scoped to exactly this agent's task, no more
- Includes the context the agent needs (relevant files, current state, constraints)
- States what "done" looks like
- States what the agent should not touch (other agents' work, shared state files)
- Matches the prompt style to the agent type (research, planning, coding)

### Cleanup

Recycle stale panes when the workspace needs clearing:

- For each idle/stale pane: terminate the old agent session gracefully
- Leave clean shell prompts ready for new agents
- Recycle panes rather than destroying and recreating them: the pane layout is part of your workspace ergonomics, and rebuilding it is wasted motion

## Anti-patterns

- **Untracked lanes.** Agents running without anyone knowing what they're working on. Every lane should have a known assignment.
- **Stale accumulation.** Letting finished sessions sit open. They add visual noise and tempt you to reuse context that's probably degraded.
- **Over-packing.** Too many agents in too many panes. The failure mode is specific: the meta-agent's own context fills with status-tracking, lanes start duplicating work because nobody can keep the full picture in view, and you spend more time coordinating than producing. Use the minimum number of concurrent agents that the work actually requires.
- **Manual-only tracking.** Keeping lane state only in your head. Write it down. A state file that lists pane assignments is cheap insurance against losing track.
