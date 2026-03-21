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
