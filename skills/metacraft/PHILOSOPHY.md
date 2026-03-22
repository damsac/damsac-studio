# Philosophy

## The meta-skill is naming the unnamed

Agentic development creates a new class of problems that don't have names yet. Context silently compresses. Intentions degrade across handoffs. Agents produce plausible echoes of results that pass casual inspection. You build momentum without noticing you've drifted.

These aren't bugs. They're the physics of the medium. And the primary skill isn't prompting, isn't architecture, isn't tool selection. It's the ability to notice what's happening, name it sharply, and turn that name into a constraint.

Naming isn't commentary. It's control. "Vision compression" isn't a metaphor: it's a bug report that produces an architectural fix. "Plausible echo" isn't literary critique: it's an attack class you can defend against.

## The recursion

Naming isn't a one-shot act. You name the thing. Then you name the frame around the thing. Then you step outside the frame, look at it, and choose a different frame. Each level up dissolves a problem that was intractable at the level below.

An agent skips a design review. You name the pattern: "prompts must make critical steps into hard requirements, not suggestions." That's naming the thing. Then you notice that you keep discovering these failures mid-session, when the cost of correction is high. You name the frame: "verification should happen at stage boundaries, not at the end." Then you step outside that frame and ask: why am I the one catching this? The answer produces the meta-lane: a dedicated agent whose only job is to hold strategic context, run check-ins, and catch drift before it compounds.

This recursion, building and watching yourself build at the same time, and letting the watching change the building, is the core loop. The process is a product. It evolves through use, not through design.

## The meta-lane

The meta-process is too complex for one person to hold. You need a collaborator that carries the context you can't.

A dedicated meta-agent, running in its own context, holds the strategic state while work agents handle implementation. It never descends into code. Its context stays clean, purely strategic, so it can manage complex projects over weeks without losing the thread. When your attention is on one lane, it tracks the others. When you need to spin up a new agent, it drafts the prompt. When context runs thin, it handles the handoff: state to disk, clean checkpoint, smooth resumption.

The human provides direction, taste, and the judgment calls that only come from using the product. The meta-agent provides working memory, context management, and a structured surface for decisions to happen on. Neither side is complete alone. The human without the meta-lane drowns in cognitive load. The meta-lane without the human optimizes for the wrong thing. The system is the relationship.

## Artifact-first epistemology

LLMs produce high-likelihood text, not ground-truth states. If your evaluation channel is self-report, you've built a system whose observable is optimized for plausibility. That's a recipe for being deceived by a machine that isn't even trying to deceive.

The correction: truth lives in externalized, falsifiable objects. Diffs, test results, repo state, build output. Not in what the agent says it did, but in what the artifacts show.

## The compiler pipeline

Once words compile, the engineering material isn't code. It's intention. And intention is slippery, lossy, and adversarial to compression. Large projects die by a thousand tiny lossy compressions from "why" into "how," until the system becomes a very competent implementation of yesterday's degraded intention.

The pipeline that survives this:

**intent -> plan -> constrained execution -> verification -> mergeable artifact**

Each stage is a different kind of work, often best done by a different agent type, with explicit handoffs and verification gates between them.

## Context is a scarce resource

Every context window is a budget. Every agent session is a memory that will eventually compact. This isn't a limitation to fight: it's a physical constraint to design around, the way you design around network latency or disk throughput.

The implications are architectural. You don't put strategic planning and line-by-line debugging in the same context for the same reason you don't put your database and your web server on the same box when one of them is going to eat all the RAM. Separate concerns get separate contexts. State that matters lives on disk, not in a window that will compress it away. And the unit of work isn't a file or a feature: it's a portfolio of concurrent cognitive threads with explicit coordination surfaces.

Session boundaries, compaction events, handoffs between agents: these aren't interruptions. They're forcing functions that make you crystallize what actually matters. The discipline of writing state to disk before compaction hits is the discipline of knowing what you know.
