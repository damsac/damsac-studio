# Typed Analytics Events — SDK API Redesign

**Date**: 2026-03-21
**Status**: Proposed

## Problem

The SDK's public API is untyped. Events are tracked via `track(_ event: String, properties: [String: Any])` and `trackLLMRequest(...)` (15+ positional parameters). This means:

- No compile-time safety on event names or property shapes
- Murmur wraps `trackLLMRequest` in its own builder struct (`LLMRequestEvent` in `AnalyticsHelpers.swift`)
- Property keys are stringly-typed — typos compile fine
- No shared contract between the SDK and the API

## Design

### AnalyticsEvent Protocol

The SDK defines a single protocol. An event *is* its properties — no nesting, no wrapper:

```swift
public protocol AnalyticsEvent: Codable, Sendable {
    static var eventName: String { get }
}
```

The SDK provides a generic track method:

```swift
extension StudioAnalytics {
    public static func track<E: AnalyticsEvent>(_ event: E)
}
```

Internally, `track<E>` encodes `E` via `JSONEncoder` (with `.convertToSnakeCase` key strategy) into a JSON dictionary, constructs an internal `Event`, and enqueues it. The `Event` struct is not public.

### LLMRequestEvent (SDK-provided)

LLM tracking is a studio-level concern. The SDK defines this as a concrete struct:

```swift
public struct LLMRequestEvent: AnalyticsEvent {
    public static let eventName = "llm.request"

    public let requestId: UUID
    public let conversationId: UUID
    public let callType: String
    public let tokensIn: Int
    public let tokensOut: Int
    public let model: String
    public let costMicros: Int64
    public let latencyMs: Int
    public let streaming: Bool
    public let turnNumber: Int
    public let conversationMessages: Int
    public let toolCalls: [String]
    public let actionCount: Int
    public let parseFailureCount: Int
    public let hasTextResponse: Bool
    public var ttftMs: Int?
    public var variant: String?
    public var itemsCount: Int?
    public var error: String?
    public var errorStatusCode: Int?

    // Custom encode(to:) emits tool_call_count derived from toolCalls.count
    // CodingKeys enforce snake_case wire format
    // JSONEncoder uses .convertToSnakeCase — UUID encodes as lowercase uuidString
}
```

### Murmur-Defined Events

Murmur defines its own event structs conforming to `AnalyticsEvent`. These live in Murmur, not the SDK:

```swift
struct AppLaunched: AnalyticsEvent {
    static let eventName = "app.launch"
}

struct RecordingStarted: AnalyticsEvent {
    static let eventName = "recording.start"
    let source: String
}

struct RecordingComplete: AnalyticsEvent {
    static let eventName = "recording.complete"
    let durationMs: Int
    let transcriptLength: Int
}

struct EntryCreated: AnalyticsEvent {
    static let eventName = "entry.created"
    let category: String
    let source: String
}

struct EntryCompleted: AnalyticsEvent {
    static let eventName = "entry.completed"
    let category: String
    let ageHours: Int
    let source: String
}

struct EntryArchived: AnalyticsEvent {
    static let eventName = "entry.archived"
    let category: String
    let ageHours: Int
    let source: String
}

struct EntryDeleted: AnalyticsEvent {
    static let eventName = "entry.deleted"
    let category: String
    let ageHours: Int
    let source: String
}

struct CreditCharged: AnalyticsEvent {
    static let eventName = "credits.charged"
    let requestId: UUID
    let credits: Int64
    let balanceAfter: Int64
}
```

### What Gets Removed

**SDK:**
- `trackLLMRequest(...)` free function — replaced by `LLMRequestEvent` struct
- `track(_ event: String, properties: [String: Any])` — replaced by `track<E: AnalyticsEvent>`
- `[String: Any]` from `Event.properties` internal representation

**Murmur:**
- `LLMRequestEvent` in `AnalyticsHelpers.swift` — replaced by SDK's `LLMRequestEvent`
- All raw `StudioAnalytics.track("string", properties: [...])` calls — replaced by typed events

### Internal Event Encoding

The internal `Event` struct changes `properties` from `[String: Any]` to `Data` (raw JSON bytes from `JSONEncoder`). When assembling batch payloads, properties `Data` is deserialized back to `[String: Any]` via `JSONSerialization` for inclusion in the batch dictionary. This avoids needing a custom `AnyCodableValue` type.

The `session.start` event emitted internally by `Session` becomes a private `SessionStartEvent` struct conforming to `AnalyticsEvent`.

This is an atomic change across both repos — the SDK and Murmur are updated together. There is no phased migration since Murmur is the only consumer.

The persistence layer (JSON files on disk) and network layer (POST to `/v1/events`) continue to produce the same wire format:

```json
{
  "id": "<uuid>",
  "app_id": "<appId>",
  "event": "entry.created",
  "timestamp": "<ISO8601>",
  "properties": {"category": "todo", "source": "voice"},
  "context": {"sdk_version": "0.3.0", ...}
}
```

### Wire Format

No changes. The Go API receives the same JSON. The SDK guarantees correctness via `Codable` instead of trusting `[String: Any]`.

### What Stays the Same

- `DeviceContext`, `Session`, `EventQueue`, `Persistence`, `NetworkClient`, `ConnectivityMonitor` — unchanged
- Batch format, flush logic, retry strategy — unchanged
- Go API ingest handler, database schema — unchanged
- `flush()` and `configure(...)` public API — unchanged
