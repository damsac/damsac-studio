# LLM Tracking & Agent Behavior Analytics

**Date:** 2026-03-15
**Status:** Draft
**Context:** Extends the events defined in the [MVP design spec](superpowers/specs/2026-03-15-damsac-studio-mvp-design.md). Replaces the "Events to Track in Murmur" section in `spec.md` for LLM-related events.

## Goals

1. **Cost optimization** — know exactly where money goes per feature, per session, per conversation
2. **Agent behavior visibility** — detect when the agent does weird things (excessive tool calls, parse failures, unnecessary clarification loops)
3. **Extensible schema** — all properties live in the JSON `properties` blob, so adding new fields requires no migration

## Design Principle

One `llm.request` event per LLM API call. Everything about that call — tokens, timing, tools, errors — lives on that single event. Multi-turn conversations are linked by `conversation_id`. Per-tool-call detail is deferred to a future `llm.tool_call` event type if needed.

---

## Events

### `llm.request`

Emitted once per LLM API call. This is the primary event for cost and behavior analysis.

#### Properties

**Identification & Linking**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `request_id` | string (UUID) | yes | Unique per API call. Generated client-side. Future `llm.tool_call` events link back to this. |
| `conversation_id` | string (UUID) | yes | Shared across all turns in a multi-turn conversation. One-shot calls (composition, layout refresh) get a unique ID per call. |
| `call_type` | string | yes | Which code path triggered the call. One of: `"agent"`, `"composition"`, `"layout_refresh"`, `"extraction"` |

**Token Usage**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `tokens_in` | int | yes | Input tokens reported by API response |
| `tokens_out` | int | yes | Output tokens reported by API response |
| `model` | string | yes | Model identifier as sent to the API, e.g. `"anthropic/claude-haiku-4.5"` |
| `cost_micros` | int64 | yes | Computed USD cost in micros (1e-6 dollars) using current `ServicePricing`. Enables raw cost analysis independent of the credit system. |

**Timing**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `latency_ms` | int | yes | Total request time: request sent to response complete |
| `ttft_ms` | int | no | Time to first token. Only set for streaming requests. |
| `streaming` | bool | yes | Whether the actual HTTP transport used SSE streaming. Note: `Pipeline.processWithAgentStreaming()` can fall back to non-streaming if the LLM doesn't support it — `streaming` reflects the transport used, not the caller's intent. |

**Conversation Context**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `turn_number` | int | yes | Which turn in the conversation (1-indexed). Composition and layout refresh are always 1. |
| `conversation_messages` | int | yes | `LLMConversation.messageCount` read immediately before the HTTP request is sent (inside `runTurn`/`processStreaming`, not at the Pipeline call site). Signals context window pressure. |

**Agent Behavior**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `tool_calls` | [string] | yes | Tool names invoked by the model, in order. e.g. `["create_entries", "update_memory", "update_layout"]`. Empty array if no tool calls. |
| `tool_call_count` | int | yes | Length of `tool_calls`. Redundant but avoids JSON array parsing in SQL queries. |
| `action_count` | int | yes | Total actions produced. Per call type: `agent` = `AgentResponse.actions.count` (a `create_entries` with 3 entries = 3 actions), `composition` = number of items in the composed layout, `layout_refresh` = number of `LayoutOperation`s returned, `extraction` = number of entries extracted. |
| `parse_failure_count` | int | yes | Number of tool calls that failed JSON decoding. Non-zero indicates agent output quality issues. |
| `has_text_response` | bool | yes | Model responded with text only (no tool calls) — a clarifying question or standalone summary. Maps to `AgentResponse.textResponse != nil`. Note: the agent normally returns text *alongside* tool calls (status messages) — that does NOT set this flag. This flag catches the "agent asked a question instead of acting" case. |

**Feature-Specific (nullable)**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `variant` | string | no | `"scanner"` or `"navigator"`. Set for `agent`, `composition`, and `layout_refresh` call types. Null for `extraction`. For `agent` calls, this reflects the last variant set on `PPQLLMService.compositionVariant` by `AppState` — i.e., the currently active home view variant. |
| `items_count` | int | no | Number of items in composed layout. Set for `composition` calls only. |

**Error (nullable)**

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `error` | string | no | Error type when the API request failed. Null on success. Values: `"http_error"`, `"parse_error"`, `"timeout"`, `"network"`. Only set for failures that occur during or after the HTTP call — pre-flight failures (insufficient credits, empty transcript) do not emit `llm.request` events since no API call was made. |
| `error_status_code` | int | no | HTTP status code on API errors (e.g. 429, 500). Null if not an HTTP error. |

#### Example Payloads

**Agent call (success, multi-turn):**
```json
{
  "event": "llm.request",
  "timestamp": "2026-03-15T14:30:00Z",
  "properties": {
    "request_id": "a1b2c3d4-...",
    "conversation_id": "e5f6a7b8-...",
    "call_type": "agent",
    "tokens_in": 3200,
    "tokens_out": 580,
    "model": "anthropic/claude-haiku-4.5",
    "cost_micros": 6402,
    "latency_ms": 1850,
    "ttft_ms": 290,
    "streaming": true,
    "turn_number": 2,
    "conversation_messages": 7,
    "tool_calls": ["create_entries", "update_memory", "update_layout"],
    "tool_call_count": 3,
    "action_count": 5,
    "parse_failure_count": 0,
    "has_text_response": false,
    "variant": "scanner"
  }
}
```

**Composition call (success):**
```json
{
  "event": "llm.request",
  "timestamp": "2026-03-15T14:29:00Z",
  "properties": {
    "request_id": "f1e2d3c4-...",
    "conversation_id": "b9a8c7d6-...",
    "call_type": "composition",
    "tokens_in": 1800,
    "tokens_out": 420,
    "model": "anthropic/claude-haiku-4.5",
    "cost_micros": 4095,
    "latency_ms": 2100,
    "streaming": false,
    "turn_number": 1,
    "conversation_messages": 2,
    "tool_calls": ["compose_view"],
    "tool_call_count": 1,
    "action_count": 1,
    "parse_failure_count": 0,
    "has_text_response": false,
    "variant": "navigator",
    "items_count": 5
  }
}
```

**Failed request:**
```json
{
  "event": "llm.request",
  "timestamp": "2026-03-15T14:31:00Z",
  "properties": {
    "request_id": "d4c3b2a1-...",
    "conversation_id": "e5f6a7b8-...",
    "call_type": "agent",
    "tokens_in": 0,
    "tokens_out": 0,
    "model": "anthropic/claude-haiku-4.5",
    "cost_micros": 0,
    "latency_ms": 30200,
    "streaming": true,
    "turn_number": 1,
    "conversation_messages": 2,
    "tool_calls": [],
    "tool_call_count": 0,
    "action_count": 0,
    "parse_failure_count": 0,
    "has_text_response": false,
    "error": "timeout",
    "error_status_code": null
  }
}
```

---

### `credits.charged`

Emitted when credits are deducted for an LLM call. Separate from `llm.request` because credits are a business concern (balance tracking, top-ups) distinct from the API call itself.

| Property | Type | Required | Description |
|----------|------|----------|-------------|
| `request_id` | string (UUID) | yes | Links to the `llm.request` that triggered this charge |
| `credits` | int | yes | Credits charged (internal unit: 1 credit = $0.001) |
| `balance_after` | int | yes | Credit balance after this charge |

---

## SDK Integration Points

Where each property comes from in the Murmur codebase. This tells you exactly where to add `StudioAnalytics.track()` calls.

### Required code changes in MurmurCore

These changes to existing types are needed before the tracking properties can be populated:

1. **`LLMConversation`** — add `public let id: UUID = UUID()` property. Generated in `init()`. This becomes the `conversation_id`.
2. **`LLMConversation`** — add `public private(set) var turnCount: Int = 0` property. Increment in `runTurn`/`processStreaming` before the HTTP call. This becomes `turn_number`.

Both changes are in `Packages/MurmurCore/Sources/MurmurCore/LLMService.swift`.

### Call sites

| Call type | Code path | Trigger |
|-----------|-----------|---------|
| `agent` | `Pipeline.processWithAgent()` / `processWithAgentStreaming()` | User voice/text input processed by agent |
| `composition` | `PPQLLMService.composeHomeView()` via `AppState.requestHomeComposition()` | Home screen cold start |
| `layout_refresh` | `PPQLLMService.refreshLayout()` via `AppState.requestLayoutRefresh()` | Background layout diff after cache hit |
| `extraction` | `Pipeline.extractEntries()` (legacy path) | Entry extraction without agent tools |

### Property sources

| Property | Source |
|----------|--------|
| `request_id` | Generate `UUID()` before the HTTP call |
| `conversation_id` | `LLMConversation.id` (see Required Code Changes above). One-shot calls create a throwaway conversation, so they get a unique ID automatically. |
| `call_type` | Known at the call site — each method maps to exactly one type |
| `tokens_in`, `tokens_out` | `AgentResponse.usage` / `TokenUsage` — already parsed from API response in `parseUsage()` |
| `model` | `PPQLLMService.model` property |
| `cost_micros` | Compute from `ServicePricing`: `(inputTokens * inputUSDPer1MMicros + outputTokens * outputUSDPer1MMicros) / 1_000_000` |
| `latency_ms` | Wrap the HTTP call in `CFAbsoluteTimeGetCurrent()` or `ContinuousClock` |
| `ttft_ms` | In `StreamingResponseAccumulator`: record time of first non-empty chunk delta |
| `streaming` | Reflects actual HTTP transport: `true` if SSE was used, `false` if standard request/response. Note: `processWithAgentStreaming` can fall back to non-streaming — check which path actually executed. |
| `turn_number` | `LLMConversation.turnCount` (see Required Code Changes above). |
| `conversation_messages` | `LLMConversation.messageCount` — read before the call |
| `tool_calls` | For `agent`: `AgentResponse.toolCallGroups.map(\.toolName)`. For `composition`: `["compose_view"]`. For `layout_refresh`: `["update_layout"]`. For `extraction`: `["create_entries"]`. Non-agent call types use forced tool choice, so the tool name is known statically. |
| `tool_call_count` | `toolCallGroups.count` |
| `action_count` | `AgentResponse.actions.count` |
| `parse_failure_count` | `AgentResponse.parseFailures.count` |
| `has_text_response` | `AgentResponse.textResponse != nil` |
| `variant` | `PPQLLMService.compositionVariant` |
| `items_count` | Count items in parsed `HomeComposition.sections` |
| `error` | Catch errors from `runTurn` / streaming, classify by type |
| `error_status_code` | `PPQError.httpError(statusCode:)` — already captured |
| `credits`, `balance_after` | `CreditReceipt.creditsCharged`, `CreditReceipt.newBalance` |

### SDK helper

The generic `StudioAnalytics.track()` works, but a typed helper avoids property typos:

```swift
extension StudioAnalytics {
    static func trackLLMRequest(
        requestId: UUID,
        conversationId: UUID,
        callType: String,         // "agent", "composition", "layout_refresh", "extraction"
        tokensIn: Int,
        tokensOut: Int,
        model: String,
        costMicros: Int64,
        latencyMs: Int,
        ttftMs: Int? = nil,
        streaming: Bool,
        turnNumber: Int,
        conversationMessages: Int,
        toolCalls: [String],
        actionCount: Int,
        parseFailureCount: Int,
        hasTextResponse: Bool,
        variant: String? = nil,
        itemsCount: Int? = nil,
        error: String? = nil,
        errorStatusCode: Int? = nil
    ) {
        var props: [String: Any] = [
            "request_id": requestId.uuidString,
            "conversation_id": conversationId.uuidString,
            "call_type": callType,
            "tokens_in": tokensIn,
            "tokens_out": tokensOut,
            "model": model,
            "cost_micros": costMicros,
            "latency_ms": latencyMs,
            "streaming": streaming,
            "turn_number": turnNumber,
            "conversation_messages": conversationMessages,
            "tool_calls": toolCalls,
            "tool_call_count": toolCalls.count,
            "action_count": actionCount,
            "parse_failure_count": parseFailureCount,
            "has_text_response": hasTextResponse,
        ]
        if let ttftMs { props["ttft_ms"] = ttftMs }
        if let variant { props["variant"] = variant }
        if let itemsCount { props["items_count"] = itemsCount }
        if let error { props["error"] = error }
        if let errorStatusCode { props["error_status_code"] = errorStatusCode }

        track("llm.request", properties: props)
    }
}
```

---

## Queries

SQLite queries against the events table for answering key questions. These power the htmx dashboard views or ad-hoc analysis.

### Cost per feature (daily)

```sql
SELECT
  date(timestamp) AS day,
  json_extract(properties, '$.call_type') AS call_type,
  SUM(json_extract(properties, '$.cost_micros')) / 1000000.0 AS cost_usd,
  COUNT(*) AS requests,
  SUM(json_extract(properties, '$.tokens_in')) AS total_tokens_in,
  SUM(json_extract(properties, '$.tokens_out')) AS total_tokens_out
FROM events
WHERE event = 'llm.request'
  AND app_id = 'murmur-ios'
  AND timestamp >= date('now', '-30 days')
GROUP BY day, call_type
ORDER BY day DESC, cost_usd DESC;
```

### Conversation depth distribution

```sql
SELECT
  json_extract(properties, '$.conversation_id') AS conv_id,
  MAX(json_extract(properties, '$.turn_number')) AS max_turn,
  SUM(json_extract(properties, '$.tokens_in')) AS total_tokens_in,
  SUM(json_extract(properties, '$.cost_micros')) / 1000000.0 AS total_cost_usd
FROM events
WHERE event = 'llm.request'
  AND json_extract(properties, '$.call_type') = 'agent'
  AND app_id = 'murmur-ios'
GROUP BY conv_id
ORDER BY max_turn DESC;
```

### Token growth per turn (context accumulation)

```sql
SELECT
  json_extract(properties, '$.turn_number') AS turn,
  AVG(json_extract(properties, '$.tokens_in')) AS avg_tokens_in,
  AVG(json_extract(properties, '$.conversation_messages')) AS avg_messages,
  COUNT(*) AS sample_size
FROM events
WHERE event = 'llm.request'
  AND json_extract(properties, '$.call_type') = 'agent'
  AND app_id = 'murmur-ios'
GROUP BY turn
ORDER BY turn;
```

### Tool usage frequency

```sql
SELECT
  je.value AS tool_name,
  COUNT(*) AS times_used
FROM events,
  json_each(json_extract(properties, '$.tool_calls')) AS je
WHERE event = 'llm.request'
  AND app_id = 'murmur-ios'
  AND timestamp >= date('now', '-7 days')
GROUP BY tool_name
ORDER BY times_used DESC;
```

### Error rate

```sql
SELECT
  date(timestamp) AS day,
  COUNT(*) AS total_requests,
  SUM(CASE WHEN json_extract(properties, '$.error') IS NOT NULL THEN 1 ELSE 0 END) AS errors,
  ROUND(100.0 * SUM(CASE WHEN json_extract(properties, '$.error') IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*), 1) AS error_pct
FROM events
WHERE event = 'llm.request'
  AND app_id = 'murmur-ios'
  AND timestamp >= date('now', '-14 days')
GROUP BY day
ORDER BY day DESC;
```

### Parse failure rate (agent quality)

```sql
SELECT
  date(timestamp) AS day,
  SUM(json_extract(properties, '$.parse_failure_count')) AS parse_failures,
  SUM(json_extract(properties, '$.tool_call_count')) AS total_tool_calls,
  ROUND(100.0 * SUM(json_extract(properties, '$.parse_failure_count'))
    / MAX(SUM(json_extract(properties, '$.tool_call_count')), 1), 1) AS failure_pct
FROM events
WHERE event = 'llm.request'
  AND json_extract(properties, '$.call_type') = 'agent'
  AND app_id = 'murmur-ios'
GROUP BY day
ORDER BY day DESC;
```

### Credit accuracy audit

Note: small positive drift (1-2 credits) is expected — `ServicePricing.credits(for:)` uses ceiling division and a minimum charge of 1 credit, so the credit charge will always be >= the raw cost.

```sql
SELECT
  r.timestamp,
  json_extract(r.properties, '$.cost_micros') AS cost_micros,
  json_extract(c.properties, '$.credits') AS credits_charged,
  -- Raw expected credits before ceiling/minimum (for comparison only)
  ROUND(json_extract(r.properties, '$.cost_micros') / 1000.0, 2) AS raw_expected,
  json_extract(c.properties, '$.credits')
    - MAX(1, CAST(ROUND(json_extract(r.properties, '$.cost_micros') / 1000.0 + 0.4999) AS INTEGER)) AS drift
FROM events r
JOIN events c
  ON json_extract(r.properties, '$.request_id') = json_extract(c.properties, '$.request_id')
WHERE r.event = 'llm.request'
  AND c.event = 'credits.charged'
  AND r.app_id = 'murmur-ios'
ORDER BY r.timestamp DESC
LIMIT 50;
```

---

## Future Extensions

These are **not in scope** for Phase 1 but the schema supports adding them without migration.

### `llm.tool_call` event (per-tool-call detail)

If parse failures or tool execution issues become a problem, emit one event per tool call:

| Property | Type | Description |
|----------|------|-------------|
| `request_id` | UUID | Links to parent `llm.request` |
| `tool_name` | string | e.g. `"create_entries"` |
| `action_count` | int | Actions produced by this tool call |
| `success` | bool | Whether the tool call parsed and executed |
| `error` | string | Parse/execution error description |
| `execution_ms` | int | Time to execute the tool (SwiftData writes, layout updates) |

### Input token composition

Break down what contributed to `tokens_in`:

| Property | Type | Description |
|----------|------|-------------|
| `system_prompt_chars` | int | Character count of system prompt (including temporal context + memory) |
| `user_content_chars` | int | Character count of user message (transcript + entry context + layout instructions) |
| `history_messages` | int | Number of conversation history messages |
| `tool_def_count` | int | Number of tool definitions in the request |

Useful for understanding why token costs grow — is it the conversation history, the entry list, or the agent memory?

### Conversation truncation tracking

When `LLMConversation.truncate(keepingLast:)` fires:

| Property | Type | Description |
|----------|------|-------------|
| `messages_before` | int | Message count before truncation |
| `messages_after` | int | Message count after |
| `conversation_id` | UUID | Which conversation was truncated |

---

## Relationship to Other Events

The MVP spec defines user behavior events (`entry.created`, `recording.complete`, etc.) and error events (`error.transcription`, `error.parse`, `error.network`). Those remain unchanged. The changes here are:

1. **`llm.request` replaces the old `llm.request`** — same event name, expanded properties
2. **`llm.error` is removed** — errors are a property on `llm.request` (see `error` field)
3. **`llm.composition` is removed** — composition-specific data (`variant`, `items_count`) is now on `llm.request` when `call_type = "composition"`
4. **`credits.charged` gains `request_id`** — links charges to requests
5. **`error.parse` remains** — for non-LLM parse errors (e.g. local JSON decode issues unrelated to an API call)
