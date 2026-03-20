import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages analytics session tracking with a 5-minute inactivity timeout.
///
/// A new session is started when:
/// - The first event is tracked (no active session)
/// - The app returns to foreground after >5 minutes in background
/// - No event has been tracked for >5 minutes
final class Session: @unchecked Sendable {
    /// Inactivity timeout in seconds.
    static let timeoutInterval: TimeInterval = 5 * 60 // 5 minutes

    private let lock = NSLock()
    private var _sessionId: UUID?
    private var _lastActivityTime: Date?
    private var _backgroundTime: Date?
    private var onNewSession: ((UUID) -> Void)?

    init(onNewSession: ((UUID) -> Void)? = nil) {
        self.onNewSession = onNewSession
        setupNotifications()
    }

    /// The current session ID. Returns nil if no session is active.
    var sessionId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _sessionId?.uuidString
    }

    /// Called when an event is about to be tracked.
    /// Returns the session ID to use, starting a new session if needed.
    @discardableResult
    func touch() -> String {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()

        if shouldStartNewSession(now: now) {
            startNewSessionLocked(now: now)
        }

        _lastActivityTime = now
        return _sessionId!.uuidString
    }

    /// Checks whether a new session should be started.
    /// Must be called while holding the lock.
    private func shouldStartNewSession(now: Date) -> Bool {
        // No session yet
        guard _sessionId != nil else { return true }

        // Inactivity timeout
        if let lastActivity = _lastActivityTime,
           now.timeIntervalSince(lastActivity) > Self.timeoutInterval {
            return true
        }

        return false
    }

    /// Start a new session. Must be called while holding the lock.
    private func startNewSessionLocked(now: Date) {
        let newId = UUID()
        _sessionId = newId
        _lastActivityTime = now
        _backgroundTime = nil

        // Notify about new session (dispatched to avoid holding lock during callback)
        let callback = onNewSession
        DispatchQueue.global(qos: .utility).async {
            callback?(newId)
        }
    }

    // MARK: - App Lifecycle

    private func setupNotifications() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
        #endif
    }

    @objc private func appDidEnterBackground() {
        lock.lock()
        _backgroundTime = Date()
        lock.unlock()
    }

    @objc private func appWillEnterForeground() {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        if let backgroundTime = _backgroundTime,
           now.timeIntervalSince(backgroundTime) > Self.timeoutInterval {
            startNewSessionLocked(now: now)
        }
        _backgroundTime = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
