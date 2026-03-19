import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor and triggers
/// a callback when connectivity is restored after being offline.
final class ConnectivityMonitor: @unchecked Sendable {
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private let lock = NSLock()

    private var _isConnected: Bool = true
    private var _wasDisconnected: Bool = false
    private var onConnectivityRestored: (() -> Void)?

    /// Whether the device currently has network connectivity.
    var isConnected: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isConnected
    }

    init(onConnectivityRestored: (() -> Void)? = nil) {
        self.monitor = NWPathMonitor()
        self.queue = DispatchQueue(label: "com.studioanalytics.connectivity", qos: .utility)
        self.onConnectivityRestored = onConnectivityRestored
    }

    /// Set (or replace) the callback invoked when connectivity is restored.
    /// Must be called before `start()` for the callback to fire on the first transition.
    func setOnConnectivityRestored(_ callback: @escaping () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        onConnectivityRestored = callback
    }

    /// Start monitoring network state.
    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }
        monitor.start(queue: queue)
    }

    /// Stop monitoring.
    func stop() {
        monitor.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        lock.lock()
        let connected = path.status == .satisfied
        let wasDisconnected = _wasDisconnected

        let previouslyConnected = _isConnected
        _isConnected = connected

        if !connected {
            _wasDisconnected = true
        }

        // Connectivity restored: was offline, now online
        let shouldFlush = connected && wasDisconnected && !previouslyConnected
        if shouldFlush {
            _wasDisconnected = false
        }

        let callback = onConnectivityRestored
        lock.unlock()

        if shouldFlush {
            callback?()
        }
    }
}
