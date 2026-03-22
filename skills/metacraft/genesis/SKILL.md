---
name: genesis
description: Bootstrap a multi-agent project. Define the meta-process, resolve every open question, close the circle.
---

# Genesis

Bootstrap a new multi-agent project from scratch. Resist the urge to start working. Close the circle first.

## What this is

The genesis protocol is for the moment when you have a clear vision, capable tools, and the temptation to immediately start building. The protocol says: not yet. First, define how you'll work. Then resolve every open question. Then codify the process and persist the state. Then, and only then, begin.

This isn't bureaucracy. It's the recognition that the first ten minutes of a multi-agent project set the trajectory for everything that follows. Ambiguity that isn't resolved now becomes confusion that compounds later, across every agent, every lane, every handoff.

The same protocol works for rebooting a project that has lost coherence. When lanes have drifted, when nobody's sure what the agreements are, when the state files are stale: that's a genesis moment. Stop. Re-close the circle. Then resume.

## When to use it

- Starting a new project that will involve multiple agents or work streams
- Rebooting a project that has lost coherence
- Any time you're about to spin up workers and realize you haven't agreed on how they'll coordinate

## The pattern

Genesis has two phases: setup (define the meta-process) and initialization (make it real). Don't skip to initialization. The definitions have to be sharp before they can be codified.

### Phase 1: Setup

Define the meta-process itself. This is constitutional: you're deciding how work will happen before any work begins.

**Define the roles.** Who does what. Not just "agent A writes code." Specifically:
- What types of agents are available (research, planning, coding, meta)
- What harness each one runs in, and why (different tools have different strengths)
- How the human operator and the meta-agent divide responsibility (see [Meta-Agent](../meta-agent/SKILL.md) for the boundary)

**Define the feedback loops.** How agents report back. This is where most multi-agent projects silently fail:
- Work agents should persist significant outputs to files at known locations, not just in chat
- The human relays chat outputs to the meta-agent as needed
- The meta-agent can read persisted artifacts directly or spin up a sub-agent to review them

**Define the prompt flow.** The meta-agent drafts prompts for work agents, matched to the agent type:
- Research agents get broad exploration scope with specific reporting structure
- Planning agents get the full problem space and produce structured implementation plans
- Coding agents get narrow scope, clear acceptance criteria, and explicit boundaries on what not to touch

**Define the session lifecycle.** How panes and sessions are managed:
- Fresh session vs. continuation vs. active context management
- When to rotate harnesses
- How compaction is handled (explicit checkpoints, state to disk, clean handoffs)

### Phase 2: Initialization

Now make it real. The definitions from phase 1 become persistent artifacts.

**Resolve every open question.** The meta-agent surfaces its open threads. You go through each one, one by one. Discuss. Resolve. Record the decision. Don't batch them, don't defer them, don't wave them away as "we'll figure it out." Every unnamed assumption is a future contradiction waiting to fork across lanes.

**Codify the process.** Write it down in persistent, version-controlled files:
- **Process document**: the constitution. Roles, principles, protocols, the decisions you just made. This is what a new agent reads to understand how the project works.
- **State file**: the living dashboard. Current phase, active lanes, next actions. This is what any agent reads to understand where the project is right now.

These files are the project's immune system. When context compacts, when agents rotate, when sessions end and restart, these files are what keeps the work coherent. Update your agent memory files so future sessions know the agreements without having to re-read everything.

Consider keeping these files in a separate repo from the project's source code. The meta-structure is about the process of building, not the thing being built. A separate repo keeps project diffs clean and gives the meta-process its own version history.

**Close the circle.** Before spinning up the first worker, verify:
- Every open question has a recorded answer
- The process is version-controlled
- The state file reflects reality
- Any agent could read these files cold and know how to participate

Then begin. The meta-process is now running. From here, the [Meta-Agent](../meta-agent/SKILL.md) manages it using [Session Lifecycle](../session-lifecycle/SKILL.md), [Tmux Lanes](../tmux-lanes/SKILL.md), and [Gather](../gather/SKILL.md).

## Anti-patterns

- **Rushing to start.** The excitement of a clear vision makes process feel like friction. It's not. It's the foundation.
- **Deferring open questions.** "We'll figure it out as we go" means "each agent will figure it out differently and we'll spend time reconciling."
- **Over-engineering the process.** If your process document is longer than a page, you're designing a bureaucracy, not a workflow. Scale the ceremony to the complexity.
- **Skipping for small projects.** Even a two-agent project benefits from a few minutes of explicit agreement on how they'll coordinate. Scale down, but don't skip.
