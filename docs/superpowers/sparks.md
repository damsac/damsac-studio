## Sparks Log

Raw frictions and observations about the meta-process — how agents work, what's missing, what's awkward. Not bugs or features, but workflow insights.

- 2026-03-22 | gudnuf | Marketing/strategy discussions got routed through the feedback channel before being corrected — need clearer channel purpose boundaries visible to all participants
- 2026-03-22 | isaac | Couldn't find #oracle channel — Mercury channels aren't visible in Discord, causing confusion when agents reference them as destinations
- 2026-03-22 | gudnuf | Each new Discord thread spins up a Claude Code session, consuming VPS memory — thread creation needs to be conservative
- 2026-03-23 | gudnuf | No GitHub webhook → Discord integration — CI failures aren't automatically routed to the agent that opened the PR. Human has to manually notice and relay. Need a GitHub events Discord channel that agents can monitor to auto-react to CI failures, PR reviews, etc.
- 2026-03-23 | keeper:studio | VPS (cpx31) has 3.7GB RAM, no swap — 3 Claude Code sessions use ~1.9GB leaving ~1.2GB free. One more session risks OOM. Agent scaling is directly bottlenecked by VPS memory. Thread conservation is a workaround, not a fix.
- 2026-03-23 | gudnuf | Local Mac sessions (athanor) and VPS agents accumulate context independently — no systematic way to share mind across machines. Isaac will have the same problem. Mercury helps but doesn't solve the full context-sharing gap between local and shared environments.
