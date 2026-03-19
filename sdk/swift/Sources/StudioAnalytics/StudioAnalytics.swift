import Foundation

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
/// StudioAnalytics.track("entry.created", properties: [
///     "category": "todo",
///     "source": "voice"
/// ])
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

    private init() {}

    // MARK: - Public API

    /// Configure the analytics SDK. Must be called before `track()`.
    ///
    /// - Parameters:
    ///   - appId: Your application identifier (e.g., "murmur-ios")
    ///   - endpoint: The analytics server URL (e.g., "https://analytics.yourdomain.com")
    ///   - apiKey: The API key for authentication
    public static func configure(appId: String, endpoint: String, apiKey: String) {
        shared.configureInstance(appId: appId, endpoint: endpoint, apiKey: apiKey)
    }

    /// Track a generic analytics event.
    ///
    /// - Parameters:
    ///   - event: The event name (e.g., "entry.created", "session.start")
    ///   - properties: Key-value pairs of event-specific data
    public static func track(_ event: String, properties: [String: Any] = [:]) {
        shared.trackEvent(event, properties: properties)
    }

    /// Track an LLM API request with typed parameters.
    ///
    /// This helper builds the correct property names as defined in the LLM tracking spec
    /// and calls `track("llm.request", ...)` under the hood.
    ///
    /// - Parameters:
    ///   - requestId: Unique UUID per API call
    ///   - conversationId: Shared across all turns in a multi-turn conversation
    ///   - callType: One of "agent", "composition", "layout_refresh", "extraction"
    ///   - tokensIn: Input tokens reported by API response
    ///   - tokensOut: Output tokens reported by API response
    ///   - model: Model identifier (e.g., "anthropic/claude-haiku-4.5")
    ///   - costMicros: Computed USD cost in micros (1e-6 dollars)
    ///   - latencyMs: Total request time in milliseconds
    ///   - ttftMs: Time to first token (streaming only)
    ///   - streaming: Whether SSE streaming was used
    ///   - turnNumber: Which turn in the conversation (1-indexed)
    ///   - conversationMessages: Message count before the HTTP request
    ///   - toolCalls: Tool names invoked by the model, in order
    ///   - actionCount: Total actions produced
    ///   - parseFailureCount: Tool calls that failed JSON decoding
    ///   - hasTextResponse: Model responded with text only (no tool calls)
    ///   - variant: "scanner" or "navigator" (optional)
    ///   - itemsCount: Items in composed layout (composition calls only)
    ///   - error: Error type on failure (optional)
    ///   - errorStatusCode: HTTP status code on API errors (optional)
    public static func trackLLMRequest(
        requestId: UUID,
        conversationId: UUID,
        callType: String,
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

    /// Force a flush of queued events.
    public static func flush() {
        shared.flushEvents()
    }

    // MARK: - Internal

    private func configureInstance(appId: String, endpoint: String, apiKey: String) {
        lock.lock()
        defer { lock.unlock() }

        // Stop existing monitors
        connectivityMonitor?.stop()

        self.appId = appId

        guard let endpointURL = URL(string: endpoint) else {
            return
        }

        let networkClient = NetworkClient(endpoint: endpointURL, apiKey: apiKey)
        let persistence = Persistence()

        // Create a single ConnectivityMonitor. The onConnectivityRestored
        // callback is wired up after EventQueue init to break the init
        // dependency cycle (EventQueue needs the monitor; the callback
        // needs a weak reference to the queue).
        let monitor = ConnectivityMonitor()

        let queue = EventQueue(
            persistence: persistence,
            networkClient: networkClient,
            connectivityMonitor: monitor
        )
        self.eventQueue = queue

        // Now set the connectivity-restored callback and start monitoring.
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
            // Emit session.start event when a new session begins
            self?.emitSessionStart(sessionId: newSessionId.uuidString)
        }
        self.session = session

        isConfigured = true
    }

    private func trackEvent(_ event: String, properties: [String: Any]) {
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
            properties: properties,
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
            properties: [:],
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

/// A simple weak reference wrapper to avoid retain cycles in closures.
private final class Weak<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) {
        self.value = value
    }
}
