# Typed Analytics Events Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the SDK's untyped `track(_:properties:)` and `trackLLMRequest(...)` with a typed `AnalyticsEvent` protocol. Events are `Encodable & Sendable` structs — the SDK encodes them internally.

**Architecture:** The SDK defines an `AnalyticsEvent` protocol and a generic `track<E>(_:)` method. Internally, `Event.properties` changes from `[String: Any]` to `Data` (JSON bytes). `LLMRequestEvent` becomes a concrete struct in the SDK. Murmur defines its own event structs and replaces all stringly-typed call sites.

**Tech Stack:** Swift 5.9, StudioAnalytics SDK, Murmur iOS app (SwiftUI + SwiftData)

**Spec:** `docs/superpowers/specs/2026-03-21-typed-analytics-events-design.md`

---

### Task 1: Add AnalyticsEvent protocol

**Files:**
- Create: `sdk/swift/Sources/StudioAnalytics/AnalyticsEvent.swift`
- Test: `sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift`

- [ ] **Step 1: Write the failing test**

Add to test file:

```swift
final class AnalyticsEventTests: XCTestCase {

    struct TestEvent: AnalyticsEvent {
        static let eventName = "test.event"
        let category: String
        let count: Int
    }

    func testAnalyticsEventEncoding() throws {
        let event = TestEvent(category: "todo", count: 42)
        XCTAssertEqual(TestEvent.eventName, "test.event")

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(event)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["category"] as? String, "todo")
        XCTAssertEqual(dict?["count"] as? Int, 42)
    }

    func testEmptyAnalyticsEvent() throws {
        struct EmptyEvent: AnalyticsEvent {
            static let eventName = "empty.event"
        }

        let event = EmptyEvent()
        XCTAssertEqual(EmptyEvent.eventName, "empty.event")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertTrue(dict?.isEmpty ?? false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sdk/swift && swift test --filter AnalyticsEventTests 2>&1`
Expected: FAIL — `AnalyticsEvent` type not found

- [ ] **Step 3: Write the protocol**

Create `sdk/swift/Sources/StudioAnalytics/AnalyticsEvent.swift`:

```swift
import Foundation

/// A typed analytics event. Conform to this protocol and call `StudioAnalytics.track(_:)`.
///
/// The struct's stored properties become the event's JSON properties dictionary.
/// Use `Encodable` key naming — the SDK encodes with `.convertToSnakeCase`.
///
/// ```swift
/// struct EntryCreated: AnalyticsEvent {
///     static let eventName = "entry.created"
///     let category: String
///     let source: String
/// }
///
/// StudioAnalytics.track(EntryCreated(category: "todo", source: "voice"))
/// ```
public protocol AnalyticsEvent: Encodable, Sendable {
    /// The event name sent as the `event` field in the JSON payload (e.g., "entry.created").
    static var eventName: String { get }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd sdk/swift && swift test --filter AnalyticsEventTests 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=false add sdk/swift/Sources/StudioAnalytics/AnalyticsEvent.swift sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift
git -c commit.gpgsign=false commit -m "feat(sdk): add AnalyticsEvent protocol"
```

---

### Task 2: Change Event.properties to Data

**Files:**
- Modify: `sdk/swift/Sources/StudioAnalytics/Event.swift`
- Modify: `sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift`

- [ ] **Step 1: Update Event struct**

Replace the `Event` struct in `sdk/swift/Sources/StudioAnalytics/Event.swift`:

```swift
import Foundation

/// A single analytics event to be tracked and sent to the server.
struct Event: Identifiable {
    let id: UUID
    let appId: String
    let event: String
    let timestamp: Date
    let properties: Data
    let context: [String: Any]

    init(
        id: UUID = UUID(),
        appId: String,
        event: String,
        timestamp: Date = Date(),
        properties: Data = Data("{}".utf8),
        context: [String: Any] = [:]
    ) {
        self.id = id
        self.appId = appId
        self.event = event
        self.timestamp = timestamp
        self.properties = properties
        self.context = context
    }
}

// MARK: - JSON Serialization

extension Event {
    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// Convert to a JSON-compatible dictionary.
    func toJSON() -> [String: Any] {
        let propsDict = (try? JSONSerialization.jsonObject(with: properties)) as? [String: Any] ?? [:]
        return [
            "id": id.uuidString,
            "app_id": appId,
            "event": event,
            "timestamp": Self.iso8601Formatter.string(from: timestamp),
            "properties": propsDict,
            "context": context
        ]
    }

    /// Serialize to JSON data.
    func toJSONData() -> Data? {
        guard JSONSerialization.isValidJSONObject(toJSON()) else { return nil }
        return try? JSONSerialization.data(withJSONObject: toJSON(), options: [])
    }

    /// Deserialize from a JSON dictionary.
    static func fromJSON(_ dict: [String: Any]) -> Event? {
        guard
            let idString = dict["id"] as? String,
            let id = UUID(uuidString: idString),
            let appId = dict["app_id"] as? String,
            let event = dict["event"] as? String,
            let timestampString = dict["timestamp"] as? String,
            let timestamp = iso8601Formatter.date(from: timestampString)
        else {
            return nil
        }

        let propsDict = dict["properties"] as? [String: Any] ?? [:]
        let propsData = (try? JSONSerialization.data(withJSONObject: propsDict)) ?? Data("{}".utf8)
        let context = dict["context"] as? [String: Any] ?? [:]

        return Event(
            id: id,
            appId: appId,
            event: event,
            timestamp: timestamp,
            properties: propsData,
            context: context
        )
    }
}

// MARK: - Batch Serialization

extension Array where Element == Event {
    /// Serialize an array of events into the batch payload format.
    func toBatchJSON() -> [String: Any] {
        var payload: [String: Any] = ["events": self.map { $0.toJSON() }]
        if let appId = self.first?.appId {
            payload["app_id"] = appId
        }
        return payload
    }

    /// Serialize to JSON data for POST body.
    func toBatchJSONData() -> Data? {
        let payload = toBatchJSON()
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload, options: [])
    }

    /// Deserialize events from a batch JSON dictionary.
    static func fromBatchJSON(_ data: Data) -> [Event]? {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let eventDicts = json["events"] as? [[String: Any]]
        else {
            return nil
        }
        return eventDicts.compactMap { Event.fromJSON($0) }
    }
}
```

- [ ] **Step 2: Update existing tests to use Data properties**

In `StudioAnalyticsTests.swift`, update `EventSerializationTests`:

Replace test helper pattern — wherever tests create Events with `[String: Any]` properties, convert to Data:

```swift
// Helper at top of test file
private func jsonData(_ dict: [String: Any]) -> Data {
    (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
}
```

Update `testEventToJSON`:
```swift
func testEventToJSON() {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1710500000)
    let event = Event(
        id: id,
        appId: "test-app",
        event: "test.event",
        timestamp: date,
        properties: jsonData(["key": "value", "count": 42]),
        context: ["sdk_version": "0.1.0"]
    )
    // ... rest of assertions unchanged
}
```

Update `testEventRoundTrip`:
```swift
func testEventRoundTrip() {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1710500000)
    let original = Event(
        id: id,
        appId: "test-app",
        event: "llm.request",
        timestamp: date,
        properties: jsonData(["tokens_in": 100, "tokens_out": 50, "model": "test-model"]),
        context: ["app_version": "1.0.0"]
    )
    // ... rest unchanged
}
```

Update `testEventJSONDataSerialization`:
```swift
func testEventJSONDataSerialization() {
    let event = Event(
        appId: "test-app",
        event: "test.event",
        properties: jsonData(["key": "value"])
    )
    // ... rest unchanged
}
```

Update `testBatchSerialization`:
```swift
func testBatchSerialization() {
    let events = [
        Event(appId: "app", event: "event1"),
        Event(appId: "app", event: "event2", properties: jsonData(["x": 1]))
    ]
    // ... rest unchanged
}
```

Update `testLLMRequestProperties`:
```swift
func testLLMRequestProperties() {
    let requestId = UUID()
    let conversationId = UUID()

    let props: [String: Any] = [
        "request_id": requestId.uuidString,
        "conversation_id": conversationId.uuidString,
        "call_type": "agent",
        "tokens_in": 3200,
        "tokens_out": 580,
        "model": "anthropic/claude-haiku-4.5",
        "cost_micros": Int64(6402),
        "latency_ms": 1850,
        "streaming": true,
        "turn_number": 2,
        "conversation_messages": 7,
        "tool_calls": ["create_entries", "update_memory", "update_layout"],
        "tool_call_count": 3,
        "action_count": 5,
        "parse_failure_count": 0,
        "has_text_response": false,
        "ttft_ms": 290,
        "variant": "scanner",
    ]

    let event = Event(
        appId: "murmur-ios",
        event: "llm.request",
        properties: jsonData(props),
        context: [:]
    )
    // ... rest of assertions unchanged
}
```

Update `PersistenceTests` — `testWriteAndLoadBatch`:
```swift
func testWriteAndLoadBatch() {
    let events = [
        Event(appId: "test", event: "e1", properties: jsonData(["k": "v"])),
        Event(appId: "test", event: "e2", properties: jsonData(["n": 42]))
    ]
    // ... rest unchanged
}
```

Update `testDeleteBatch` and other persistence tests that create Events:
```swift
// These already use no properties, default Data("{}".utf8) is fine
let events = [Event(appId: "test", event: "e1")]  // unchanged — default properties
```

- [ ] **Step 3: Run all tests**

Run: `cd sdk/swift && swift test 2>&1`
Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git -c commit.gpgsign=false add sdk/swift/Sources/StudioAnalytics/Event.swift sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift
git -c commit.gpgsign=false commit -m "refactor(sdk): change Event.properties from [String: Any] to Data"
```

---

### Task 3: Add LLMRequestEvent struct

**Files:**
- Create: `sdk/swift/Sources/StudioAnalytics/LLMRequestEvent.swift`
- Modify: `sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift`

- [ ] **Step 1: Write the failing test**

Add to test file:

```swift
final class LLMRequestEventTests: XCTestCase {

    func testLLMRequestEventEncoding() throws {
        let requestId = UUID()
        let conversationId = UUID()

        var event = LLMRequestEvent(
            requestId: requestId,
            conversationId: conversationId,
            callType: "agent",
            tokensIn: 3200,
            tokensOut: 580,
            model: "anthropic/claude-haiku-4.5",
            costMicros: 6402,
            latencyMs: 1850,
            streaming: true,
            turnNumber: 2,
            conversationMessages: 7,
            toolCalls: ["create_entries", "update_memory", "update_layout"],
            actionCount: 5,
            parseFailureCount: 0,
            hasTextResponse: false
        )
        event.ttftMs = 290
        event.variant = "scanner"

        XCTAssertEqual(LLMRequestEvent.eventName, "llm.request")

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["request_id"] as? String, requestId.uuidString)
        XCTAssertEqual(dict["conversation_id"] as? String, conversationId.uuidString)
        XCTAssertEqual(dict["call_type"] as? String, "agent")
        XCTAssertEqual(dict["tokens_in"] as? Int, 3200)
        XCTAssertEqual(dict["tokens_out"] as? Int, 580)
        XCTAssertEqual(dict["model"] as? String, "anthropic/claude-haiku-4.5")
        XCTAssertEqual(dict["cost_micros"] as? Int64, 6402)
        XCTAssertEqual(dict["latency_ms"] as? Int, 1850)
        XCTAssertEqual(dict["streaming"] as? Bool, true)
        XCTAssertEqual(dict["turn_number"] as? Int, 2)
        XCTAssertEqual(dict["conversation_messages"] as? Int, 7)
        XCTAssertEqual(dict["tool_calls"] as? [String], ["create_entries", "update_memory", "update_layout"])
        XCTAssertEqual(dict["tool_call_count"] as? Int, 3)
        XCTAssertEqual(dict["action_count"] as? Int, 5)
        XCTAssertEqual(dict["parse_failure_count"] as? Int, 0)
        XCTAssertEqual(dict["has_text_response"] as? Bool, false)
        XCTAssertEqual(dict["ttft_ms"] as? Int, 290)
        XCTAssertEqual(dict["variant"] as? String, "scanner")
        XCTAssertNil(dict["items_count"])
        XCTAssertNil(dict["error"])
        XCTAssertNil(dict["error_status_code"])
    }

    func testLLMRequestEventOptionalFields() throws {
        let event = LLMRequestEvent(
            requestId: UUID(),
            conversationId: UUID(),
            callType: "composition",
            tokensIn: 100,
            tokensOut: 50,
            model: "test",
            costMicros: 0,
            latencyMs: 500,
            streaming: false,
            turnNumber: 1,
            conversationMessages: 2,
            toolCalls: [],
            actionCount: 0,
            parseFailureCount: 0,
            hasTextResponse: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        // Optional fields should be absent
        XCTAssertNil(dict["ttft_ms"])
        XCTAssertNil(dict["variant"])
        XCTAssertNil(dict["items_count"])
        XCTAssertNil(dict["error"])
        XCTAssertNil(dict["error_status_code"])

        // tool_call_count should be 0 for empty array
        XCTAssertEqual(dict["tool_call_count"] as? Int, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd sdk/swift && swift test --filter LLMRequestEventTests 2>&1`
Expected: FAIL — `LLMRequestEvent` type not found

- [ ] **Step 3: Write LLMRequestEvent struct**

Create `sdk/swift/Sources/StudioAnalytics/LLMRequestEvent.swift`:

```swift
import Foundation

/// Tracks an LLM API request. This is an SDK-provided event type since
/// LLM cost/latency tracking is a studio-level concern shared across apps.
///
/// ```swift
/// var event = LLMRequestEvent(
///     requestId: UUID(), conversationId: convId,
///     callType: "agent", tokensIn: 3200, tokensOut: 580,
///     model: "anthropic/claude-haiku-4.5", costMicros: 6402,
///     latencyMs: 1850, streaming: true, turnNumber: 2,
///     conversationMessages: 7, toolCalls: ["create_entries"],
///     actionCount: 5, parseFailureCount: 0, hasTextResponse: false
/// )
/// event.variant = "scanner"
/// StudioAnalytics.track(event)
/// ```
public struct LLMRequestEvent: AnalyticsEvent {
    public static let eventName = "llm.request"

    public var requestId: UUID
    public var conversationId: UUID
    public var callType: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var model: String
    public var costMicros: Int64
    public var latencyMs: Int
    public var streaming: Bool
    public var turnNumber: Int
    public var conversationMessages: Int
    public var toolCalls: [String]
    public var actionCount: Int
    public var parseFailureCount: Int
    public var hasTextResponse: Bool
    public var ttftMs: Int?
    public var variant: String?
    public var itemsCount: Int?
    public var error: String?
    public var errorStatusCode: Int?

    public init(
        requestId: UUID,
        conversationId: UUID,
        callType: String,
        tokensIn: Int,
        tokensOut: Int,
        model: String,
        costMicros: Int64,
        latencyMs: Int,
        streaming: Bool,
        turnNumber: Int,
        conversationMessages: Int,
        toolCalls: [String],
        actionCount: Int,
        parseFailureCount: Int,
        hasTextResponse: Bool
    ) {
        self.requestId = requestId
        self.conversationId = conversationId
        self.callType = callType
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.model = model
        self.costMicros = costMicros
        self.latencyMs = latencyMs
        self.streaming = streaming
        self.turnNumber = turnNumber
        self.conversationMessages = conversationMessages
        self.toolCalls = toolCalls
        self.actionCount = actionCount
        self.parseFailureCount = parseFailureCount
        self.hasTextResponse = hasTextResponse
    }

    // MARK: - Encoding

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case conversationId = "conversation_id"
        case callType = "call_type"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case model
        case costMicros = "cost_micros"
        case latencyMs = "latency_ms"
        case streaming
        case turnNumber = "turn_number"
        case conversationMessages = "conversation_messages"
        case toolCalls = "tool_calls"
        case toolCallCount = "tool_call_count"
        case actionCount = "action_count"
        case parseFailureCount = "parse_failure_count"
        case hasTextResponse = "has_text_response"
        case ttftMs = "ttft_ms"
        case variant
        case itemsCount = "items_count"
        case error
        case errorStatusCode = "error_status_code"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode UUIDs as uppercase strings to match existing wire format
        try c.encode(requestId.uuidString, forKey: .requestId)
        try c.encode(conversationId.uuidString, forKey: .conversationId)
        try c.encode(callType, forKey: .callType)
        try c.encode(tokensIn, forKey: .tokensIn)
        try c.encode(tokensOut, forKey: .tokensOut)
        try c.encode(model, forKey: .model)
        try c.encode(costMicros, forKey: .costMicros)
        try c.encode(latencyMs, forKey: .latencyMs)
        try c.encode(streaming, forKey: .streaming)
        try c.encode(turnNumber, forKey: .turnNumber)
        try c.encode(conversationMessages, forKey: .conversationMessages)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(toolCalls.count, forKey: .toolCallCount)
        try c.encode(actionCount, forKey: .actionCount)
        try c.encode(parseFailureCount, forKey: .parseFailureCount)
        try c.encode(hasTextResponse, forKey: .hasTextResponse)
        try c.encodeIfPresent(ttftMs, forKey: .ttftMs)
        try c.encodeIfPresent(variant, forKey: .variant)
        try c.encodeIfPresent(itemsCount, forKey: .itemsCount)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(errorStatusCode, forKey: .errorStatusCode)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd sdk/swift && swift test --filter LLMRequestEventTests 2>&1`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=false add sdk/swift/Sources/StudioAnalytics/LLMRequestEvent.swift sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift
git -c commit.gpgsign=false commit -m "feat(sdk): add LLMRequestEvent struct with typed encoding"
```

---

### Task 4: Update StudioAnalytics public API

**Files:**
- Modify: `sdk/swift/Sources/StudioAnalytics/StudioAnalytics.swift`
- Modify: `sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift`

- [ ] **Step 1: Write a test for the typed track method**

Add to test file:

```swift
final class TypedTrackTests: XCTestCase {

    func testTypedTrackDoesNotCrashBeforeConfigure() {
        struct SimpleEvent: AnalyticsEvent {
            static let eventName = "simple.test"
            let value: Int
        }

        // Should silently drop, not crash
        StudioAnalytics.track(SimpleEvent(value: 42))
    }
}
```

- [ ] **Step 2: Replace public API in StudioAnalytics.swift**

Replace the entire `StudioAnalytics.swift` with:

```swift
import Foundation
import os.log

/// Shared logger for the StudioAnalytics SDK.
let saLog = Logger(subsystem: "com.studioanalytics", category: "SDK")

/// StudioAnalytics — Self-hosted analytics SDK for iOS apps.
///
/// Usage:
/// ```swift
/// StudioAnalytics.configure(
///     appId: "murmur-ios",
///     endpoint: "https://analytics.yourdomain.com",
///     apiKey: "sk_murmur_live"
/// )
///
/// struct EntryCreated: AnalyticsEvent {
///     static let eventName = "entry.created"
///     let category: String
///     let source: String
/// }
///
/// StudioAnalytics.track(EntryCreated(category: "todo", source: "voice"))
/// ```
public final class StudioAnalytics: @unchecked Sendable {

    // MARK: - Singleton

    private static let shared = StudioAnalytics()
    private let lock = NSLock()

    private var appId: String?
    private var eventQueue: EventQueue?
    private var session: Session?
    private var deviceContext: DeviceContext?
    private var connectivityMonitor: ConnectivityMonitor?
    private var isConfigured: Bool = false

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private init() {}

    // MARK: - Public API

    /// Configure the analytics SDK. Must be called before `track()`.
    public static func configure(appId: String, endpoint: String, apiKey: String) {
        shared.configureInstance(appId: appId, endpoint: endpoint, apiKey: apiKey)
    }

    /// Track a typed analytics event.
    public static func track<E: AnalyticsEvent>(_ event: E) {
        guard let data = try? encoder.encode(event) else {
            saLog.error("failed to encode event: \(E.eventName)")
            return
        }
        shared.trackEvent(E.eventName, propertiesData: data)
    }

    /// Force a flush of queued events.
    public static func flush() {
        shared.flushEvents()
    }

    // MARK: - Internal

    private func configureInstance(appId: String, endpoint: String, apiKey: String) {
        lock.lock()
        defer { lock.unlock() }

        connectivityMonitor?.stop()

        self.appId = appId

        guard let endpointURL = URL(string: endpoint) else {
            saLog.error("invalid endpoint URL: \(endpoint)")
            return
        }

        let networkClient = NetworkClient(endpoint: endpointURL, apiKey: apiKey)
        let persistence = Persistence()

        let monitor = ConnectivityMonitor()

        let queue = EventQueue(
            persistence: persistence,
            networkClient: networkClient,
            connectivityMonitor: monitor
        )
        self.eventQueue = queue

        let weakQueue = Weak(queue)
        monitor.setOnConnectivityRestored { [weakQueue] in
            weakQueue.value?.requestFlush()
            networkClient.resetBackoff()
        }
        monitor.start()
        self.connectivityMonitor = monitor

        let context = DeviceContext(appId: appId)
        self.deviceContext = context

        let session = Session { [weak self] newSessionId in
            self?.emitSessionStart(sessionId: newSessionId.uuidString)
        }
        self.session = session

        isConfigured = true
        saLog.info("configured for \(appId) → \(endpoint)")

        queue.requestFlush()
    }

    private func trackEvent(_ event: String, propertiesData: Data) {
        lock.lock()
        guard isConfigured,
              let appId = self.appId,
              let queue = self.eventQueue,
              let session = self.session,
              let context = self.deviceContext else {
            lock.unlock()
            return
        }
        lock.unlock()

        let sessionId = session.touch()
        let contextDict = context.context(sessionId: sessionId)

        let analyticsEvent = Event(
            appId: appId,
            event: event,
            properties: propertiesData,
            context: contextDict
        )

        queue.enqueue(analyticsEvent)
    }

    private func emitSessionStart(sessionId: String) {
        lock.lock()
        guard isConfigured,
              let appId = self.appId,
              let queue = self.eventQueue,
              let context = self.deviceContext else {
            lock.unlock()
            return
        }
        lock.unlock()

        let contextDict = context.context(sessionId: sessionId)

        let event = Event(
            appId: appId,
            event: "session.start",
            context: contextDict
        )

        queue.enqueue(event)
    }

    private func flushEvents() {
        lock.lock()
        let queue = eventQueue
        lock.unlock()
        queue?.requestFlush()
    }
}

// MARK: - Weak Reference Helper

private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
```

Key changes from current code:
- Removed `track(_ event: String, properties: [String: Any])` method
- Removed `trackLLMRequest(...)` method
- Added `track<E: AnalyticsEvent>(_ event: E)` method
- Added static `encoder` property
- Changed `trackEvent` to accept `propertiesData: Data` instead of `properties: [String: Any]`
- `emitSessionStart` uses default empty `Data("{}".utf8)` properties

- [ ] **Step 3: Update ConfigurationGatingTests**

Replace the existing test:
```swift
final class ConfigurationGatingTests: XCTestCase {

    func testEventsDroppedBeforeConfigure() {
        struct GatingTestEvent: AnalyticsEvent {
            static let eventName = "should.be.dropped"
            let test: Bool
        }
        StudioAnalytics.track(GatingTestEvent(test: true))
        // If we get here without crashing, the test passes.
    }
}
```

- [ ] **Step 3b: Add wire format round-trip test**

This verifies the full pipeline: `JSONEncoder -> Data -> Event.properties -> toJSON() -> batch payload`. Add to `AnalyticsEventTests`:

```swift
func testTypedEventWireFormatRoundTrip() throws {
    let event = TestEvent(category: "todo", count: 42)
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    let data = try encoder.encode(event)

    let internal_event = Event(
        appId: "test",
        event: TestEvent.eventName,
        properties: data,
        context: ["sdk_version": "0.2.0"]
    )
    let json = internal_event.toJSON()
    let props = json["properties"] as? [String: Any]

    XCTAssertEqual(json["event"] as? String, "test.event")
    XCTAssertEqual(props?["category"] as? String, "todo")
    XCTAssertEqual(props?["count"] as? Int, 42)

    // Verify batch serialization works too
    let batch = [internal_event]
    let batchData = batch.toBatchJSONData()
    XCTAssertNotNil(batchData)

    if let batchData {
        let restored = [Event].fromBatchJSON(batchData)
        XCTAssertEqual(restored?.count, 1)
        XCTAssertEqual(restored?[0].event, "test.event")
        let restoredProps = (try? JSONSerialization.jsonObject(with: restored![0].properties)) as? [String: Any]
        XCTAssertEqual(restoredProps?["category"] as? String, "todo")
    }
}
```

- [ ] **Step 3c: Remove old `testLLMRequestProperties` test**

This test manually constructs a `[String: Any]` dictionary to simulate the old `trackLLMRequest` behavior. The new `LLMRequestEventTests` (Task 3) replaces its purpose. Delete `testLLMRequestProperties` from `EventSerializationTests`.

- [ ] **Step 4: Run all tests**

Run: `cd sdk/swift && swift test 2>&1`
Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git -c commit.gpgsign=false add sdk/swift/Sources/StudioAnalytics/StudioAnalytics.swift sdk/swift/Tests/StudioAnalyticsTests/StudioAnalyticsTests.swift
git -c commit.gpgsign=false commit -m "feat(sdk): replace untyped track() with typed track<E: AnalyticsEvent>()"
```

---

### Task 5: Add Murmur event structs

**Files:**
- Create: `/Users/claude/Murmur/Murmur/Services/MurmurEvents.swift`

This task works in the **Murmur repo** (`/Users/claude/Murmur`). The SDK dependency must be updated to point to the local damsac-studio SDK first (or the SDK changes pushed). Check how the dependency is configured in Murmur's Package.swift or project.yml.

- [ ] **Step 1: Update Murmur's SDK dependency to use local path**

Check how the dependency is configured:
```bash
grep -r "StudioAnalytics\|damsac-studio" /Users/claude/Murmur/Packages/ /Users/claude/Murmur/Package.swift /Users/claude/Murmur/project.yml 2>/dev/null | head -20
```

Murmur uses a remote SPM dependency on `damsac-studio`. Since the SDK changes haven't been pushed yet, temporarily update the dependency to point to the local SDK path. The method depends on what the grep reveals:

- If `project.yml` (XcodeGen): change the `url:` to `path: /Users/claude/damsac-studio/sdk/swift`
- If `Package.swift`: change `.package(url: ...)` to `.package(path: "/Users/claude/damsac-studio/sdk/swift")`
- If Xcode project directly: update via `xcodebuild -resolvePackageDependencies`

After all changes are committed to both repos, push the SDK changes and restore the remote dependency before the final Murmur commit.

- [ ] **Step 2: Create MurmurEvents.swift**

Create `/Users/claude/Murmur/Murmur/Services/MurmurEvents.swift`:

```swift
import Foundation
import StudioAnalytics

// MARK: - App Lifecycle

struct AppLaunched: AnalyticsEvent {
    static let eventName = "app.launch"
}

// MARK: - Recording

struct RecordingStarted: AnalyticsEvent {
    static let eventName = "recording.start"
    let source: String
}

struct RecordingComplete: AnalyticsEvent {
    static let eventName = "recording.complete"
    let durationMs: Int
    let transcriptLength: Int
}

// MARK: - Entry CRUD

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

// MARK: - Credits

struct CreditCharged: AnalyticsEvent {
    static let eventName = "credits.charged"
    let requestId: String  // UUID string, passed as .uuidString from caller
    let credits: Int64
    let balanceAfter: Int64
}
```

- [ ] **Step 3: Commit**

```bash
cd /Users/claude/Murmur
git -c commit.gpgsign=false add Murmur/Services/MurmurEvents.swift
git -c commit.gpgsign=false commit -m "feat: add typed analytics event structs"
```

---

### Task 6: Update Murmur call sites

**Files:**
- Modify: `/Users/claude/Murmur/Murmur/MurmurApp.swift`
- Modify: `/Users/claude/Murmur/Murmur/Services/AnalyticsHelpers.swift`
- Modify: `/Users/claude/Murmur/Murmur/Services/ConversationState.swift`
- Modify: `/Users/claude/Murmur/Murmur/Services/AppState.swift`
- Modify: `/Users/claude/Murmur/Murmur/Views/RootView.swift`
- Modify: `/Users/claude/Murmur/Murmur/Services/AgentActionExecutor.swift`

- [ ] **Step 1: Update MurmurApp.swift**

Replace:
```swift
StudioAnalytics.track("app.launch")
```
With:
```swift
StudioAnalytics.track(AppLaunched())
```

- [ ] **Step 2: Update AnalyticsHelpers.swift**

Remove the `LLMRequestEvent` struct entirely. Keep the `Duration` extension. Keep the `classifyError` helper but move it to a standalone function or small helper struct.

Replace the file with:

```swift
import Foundation
import MurmurCore
import StudioAnalytics

// MARK: - LLM Request Event Builder

/// Builder that wraps `LLMRequestEvent` with Murmur-specific conveniences:
/// computed cost from `ServicePricing`, latency from `ContinuousClock`, error classification.
struct LLMRequestTracker {
    let requestId: UUID
    let conversationId: UUID
    let callType: String
    let model: String
    let pricing: ServicePricing
    let start: ContinuousClock.Instant

    var tokensIn: Int = 0
    var tokensOut: Int = 0
    var streaming: Bool = false
    var turnNumber: Int = 1
    var conversationMessages: Int = 2
    var toolCalls: [String] = []
    var actionCount: Int = 0
    var parseFailureCount: Int = 0
    var hasTextResponse: Bool = false
    var variant: String?
    var itemsCount: Int?
    var ttftMs: Int?

    var costMicros: Int64 {
        let usage = TokenUsage(inputTokens: tokensIn, outputTokens: tokensOut)
        return Self.computeCost(usage: usage, pricing: pricing)
    }

    var latencyMs: Int {
        Int(start.duration(to: .now).totalMilliseconds)
    }

    func track() {
        var event = LLMRequestEvent(
            requestId: requestId,
            conversationId: conversationId,
            callType: callType,
            tokensIn: tokensIn,
            tokensOut: tokensOut,
            model: model,
            costMicros: costMicros,
            latencyMs: latencyMs,
            streaming: streaming,
            turnNumber: turnNumber,
            conversationMessages: conversationMessages,
            toolCalls: toolCalls,
            actionCount: actionCount,
            parseFailureCount: parseFailureCount,
            hasTextResponse: hasTextResponse
        )
        event.ttftMs = ttftMs
        event.variant = variant
        event.itemsCount = itemsCount
        StudioAnalytics.track(event)
    }

    func trackError(_ error: Error) {
        let (errorType, statusCode) = Self.classifyError(error)
        var event = LLMRequestEvent(
            requestId: requestId,
            conversationId: conversationId,
            callType: callType,
            tokensIn: 0,
            tokensOut: 0,
            model: model,
            costMicros: 0,
            latencyMs: latencyMs,
            streaming: streaming,
            turnNumber: turnNumber,
            conversationMessages: conversationMessages,
            toolCalls: [],
            actionCount: 0,
            parseFailureCount: 0,
            hasTextResponse: false
        )
        event.variant = variant
        event.error = errorType
        event.errorStatusCode = statusCode
        StudioAnalytics.track(event)
    }

    // MARK: - Shared Helpers

    static func computeCost(usage: TokenUsage, pricing: ServicePricing) -> Int64 {
        let inputCost = Int64(usage.inputTokens) * pricing.inputUSDPer1MMicros
        let outputCost = Int64(usage.outputTokens) * pricing.outputUSDPer1MMicros
        return (inputCost + outputCost) / 1_000_000
    }

    static func classifyError(_ error: Error) -> (type: String, statusCode: Int?) {
        var inner = error
        if case PipelineError.extractionFailed(let underlying) = error {
            inner = underlying
        }
        if let ppqError = inner as? PPQError {
            switch ppqError {
            case .httpError(let code, _):
                return ("http_error", code)
            case .invalidResponse, .noToolCalls:
                return ("parse_error", nil)
            }
        }
        if inner is URLError {
            return ("network", nil)
        }
        return ("unknown", nil)
    }
}

// MARK: - Duration Helpers

extension Duration {
    var totalMilliseconds: Int64 {
        let (seconds, attoseconds) = components
        return seconds * 1000 + attoseconds / 1_000_000_000_000_000
    }
}
```

- [ ] **Step 3: Update ConversationState.swift**

All references to `LLMRequestEvent(` become `LLMRequestTracker(` — the field names are identical, so only the type name changes.

Replace recording.start (~line 144):
```swift
// Old:
StudioAnalytics.track("recording.start", properties: ["source": "voice"])
// New:
StudioAnalytics.track(RecordingStarted(source: "voice"))
```

Replace recording.complete (~line 252):
```swift
// Old:
StudioAnalytics.track("recording.complete", properties: [
    "duration_ms": durationMs ?? 0,
    "transcript_length": liveText.count,
])
// New:
StudioAnalytics.track(RecordingComplete(
    durationMs: durationMs ?? 0,
    transcriptLength: liveText.count
))
```

Replace LLMRequestEvent init (~line 342):
```swift
// Old:
var event = LLMRequestEvent(
// New:
var event = LLMRequestTracker(
```

Replace credits.charged (~line 476):
```swift
// Old:
StudioAnalytics.track("credits.charged", properties: [
    "request_id": tracking.requestId.uuidString,
    "credits": credits,
    "balance_after": balance,
])
// New:
StudioAnalytics.track(CreditCharged(
    requestId: tracking.requestId.uuidString,
    credits: credits,
    balanceAfter: balance
))
```

- [ ] **Step 4: Update AppState.swift**

Replace `LLMRequestEvent(` with `LLMRequestTracker(` (~lines 194 and 259).

Replace both `credits.charged` calls (~lines 225 and 293):
```swift
// Old:
StudioAnalytics.track("credits.charged", properties: [
    "request_id": event.requestId.uuidString,
    "credits": receipt.creditsCharged,
    "balance_after": receipt.newBalance,
])
// New:
StudioAnalytics.track(CreditCharged(
    requestId: event.requestId.uuidString,
    credits: receipt.creditsCharged,
    balanceAfter: receipt.newBalance
))
```

- [ ] **Step 5: Update RootView.swift**

Replace entry.completed (~line 491):
```swift
// Old:
StudioAnalytics.track("entry.completed", properties: [
    "category": entry.category.rawValue,
    "age_hours": Int(Date().timeIntervalSince(entry.createdAt) / 3600),
    "source": "user",
])
// New:
StudioAnalytics.track(EntryCompleted(
    category: entry.category.rawValue,
    ageHours: Int(Date().timeIntervalSince(entry.createdAt) / 3600),
    source: "user"
))
```

Replace entry.archived (~line 501):
```swift
// Old:
StudioAnalytics.track("entry.archived", properties: [
    "category": entry.category.rawValue,
    "age_hours": Int(Date().timeIntervalSince(entry.createdAt) / 3600),
    "source": "user",
])
// New:
StudioAnalytics.track(EntryArchived(
    category: entry.category.rawValue,
    ageHours: Int(Date().timeIntervalSince(entry.createdAt) / 3600),
    source: "user"
))
```

Replace entry.deleted (~line 527):
```swift
// Old:
StudioAnalytics.track("entry.deleted", properties: [
    "category": deleteCategory,
    "age_hours": deleteAgeHours,
    "source": "user",
])
// New:
StudioAnalytics.track(EntryDeleted(
    category: deleteCategory,
    ageHours: deleteAgeHours,
    source: "user"
))
```

- [ ] **Step 6: Update AgentActionExecutor.swift**

Replace entry.completed (~line 134):
```swift
StudioAnalytics.track(EntryCompleted(
    category: entry.category.rawValue,
    ageHours: Int(Date().timeIntervalSince(entry.createdAt) / 3600),
    source: "agent"
))
```

Replace entry.archived (~line 149):
```swift
StudioAnalytics.track(EntryArchived(
    category: entry.category.rawValue,
    ageHours: Int(Date().timeIntervalSince(entry.createdAt) / 3600),
    source: "agent"
))
```

Replace entry.created (~line 191):
```swift
StudioAnalytics.track(EntryCreated(
    category: entry.category.rawValue,
    source: ctx.source == .voice ? "voice" : "text"
))
```

- [ ] **Step 7: Build Murmur to verify**

Run: `cd /Users/claude/Murmur && swift build 2>&1` (or use xcodebuild if the project uses Xcode)

Check Murmur's build system. If it uses `project.yml` + XcodeGen:
```bash
cd /Users/claude/Murmur && xcodegen generate && xcodebuild build -scheme Murmur -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```

Expected: Build succeeds with no errors. No remaining references to the old `track(_:properties:)` or `trackLLMRequest(...)` methods.

- [ ] **Step 8: Commit**

```bash
cd /Users/claude/Murmur
git -c commit.gpgsign=false add -A
git -c commit.gpgsign=false commit -m "feat: migrate all analytics to typed AnalyticsEvent protocol

Replace stringly-typed StudioAnalytics.track() calls with typed event
structs. Rename LLMRequestEvent to LLMRequestTracker (SDK now owns
LLMRequestEvent). All events are Encodable with compile-time safety."
```

---

### Task 7: Run SDK tests and verify wire format

**Files:** None (verification only)

- [ ] **Step 1: Run full SDK test suite**

```bash
cd /Users/claude/damsac-studio/sdk/swift && swift test 2>&1
```

Expected: All tests pass.

- [ ] **Step 2: Verify wire format hasn't changed**

Write a quick integration check — encode an LLMRequestEvent and verify the JSON keys match the old format exactly:

```bash
cd /Users/claude/damsac-studio/sdk/swift && swift test --filter LLMRequestEventTests 2>&1
```

Key checks in the test:
- `tool_call_count` is present (derived from toolCalls.count)
- UUID fields are the correct case (uppercase vs lowercase — verify against old wire format)
- Optional fields are absent when nil (not null)
- Snake_case keys match old property names exactly

- [ ] **Step 3: Verify no remaining [String: Any] in public API**

```bash
grep -r "\[String: Any\]" /Users/claude/damsac-studio/sdk/swift/Sources/StudioAnalytics/*.swift
```

Expected: Only appears in `Event.swift` (internal context dict) and `DeviceContext.swift`, NOT in any public method signature.
