import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// In-memory event queue with automatic flushing to the network.
///
/// - Queue capacity: 1000 events, drop oldest when full
/// - Flush triggers: 30-second timer, 20-event threshold, app background, connectivity restored
/// - Batches of up to 50 events per POST
/// - Background serial queue for all internal work
final class EventQueue: @unchecked Sendable {
    static let maxQueueSize = 1000
    static let flushThreshold = 20
    static let flushInterval: TimeInterval = 30
    static let maxBatchSize = 50

    private let lock = NSLock()
    private var _events: [Event] = []
    private var _isFlushing = false

    private let persistence: Persistence
    private let networkClient: NetworkClient
    private let connectivityMonitor: ConnectivityMonitor
    private let workQueue: DispatchQueue

    private var flushTimer: DispatchSourceTimer?
    #if canImport(UIKit)
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif

    init(
        persistence: Persistence,
        networkClient: NetworkClient,
        connectivityMonitor: ConnectivityMonitor
    ) {
        self.persistence = persistence
        self.networkClient = networkClient
        self.connectivityMonitor = connectivityMonitor
        self.workQueue = DispatchQueue(label: "com.studioanalytics.queue", qos: .utility)

        setupNotifications()
        startFlushTimer()
    }

    // MARK: - Enqueue

    /// Add an event to the queue.
    func enqueue(_ event: Event) {
        lock.lock()
        _events.append(event)

        // Drop oldest when over capacity
        while _events.count > Self.maxQueueSize {
            _events.removeFirst()
        }

        let shouldFlush = _events.count >= Self.flushThreshold
        lock.unlock()

        if shouldFlush {
            requestFlush()
        }
    }

    // MARK: - Flush

    /// Request a flush. Actual flushing happens on the work queue.
    func requestFlush() {
        workQueue.async { [weak self] in
            self?.flushSync()
        }
    }

    /// Synchronous flush -- sends batches until the queue is drained or an error occurs.
    /// Must be called from the work queue.
    private func flushSync() {
        lock.lock()
        guard !_isFlushing else {
            lock.unlock()
            return
        }
        _isFlushing = true
        lock.unlock()

        defer {
            lock.lock()
            _isFlushing = false
            lock.unlock()
        }

        // Don't flush if offline
        guard connectivityMonitor.isConnected else { return }

        // First, try to send any persisted batches from previous sessions
        sendPersistedBatches()

        // Then flush in-memory events
        while true {
            lock.lock()
            guard !_events.isEmpty else {
                lock.unlock()
                break
            }

            let batchSize = min(_events.count, Self.maxBatchSize)
            let batch = Array(_events.prefix(batchSize))
            lock.unlock()

            // Persist the batch first
            let filename = persistence.writeBatch(batch)

            // Send synchronously
            let result = networkClient.sendSync(batchData: batch.toBatchJSONData() ?? Data())

            switch result {
            case .success:
                // Remove from queue and delete persisted file
                lock.lock()
                if _events.count >= batchSize {
                    _events.removeFirst(batchSize)
                }
                lock.unlock()
                if let filename { persistence.deleteBatch(filename: filename) }

            case .clientError:
                // Drop events -- not retryable
                lock.lock()
                if _events.count >= batchSize {
                    _events.removeFirst(batchSize)
                }
                lock.unlock()
                if let filename { persistence.deleteBatch(filename: filename) }

            case .serverError, .networkError, .circuitOpen:
                // Events are persisted on disk for retry. Remove from memory
                // only if persistence succeeded; otherwise keep them in memory
                // so they aren't lost.
                if filename != nil {
                    lock.lock()
                    if _events.count >= batchSize {
                        _events.removeFirst(batchSize)
                    }
                    lock.unlock()
                }
                return // Stop flushing on error
            }
        }
    }

    /// Attempt to send persisted batches from disk (e.g. from a previous app session).
    private func sendPersistedBatches() {
        let batches = persistence.loadAllBatches()
        for (filename, events) in batches {
            guard let data = events.toBatchJSONData() else {
                persistence.deleteBatch(filename: filename)
                continue
            }

            let result = networkClient.sendSync(batchData: data)

            switch result {
            case .success, .clientError:
                persistence.deleteBatch(filename: filename)
            case .serverError, .networkError, .circuitOpen:
                return // Stop on first failure
            }
        }
    }

    // MARK: - Timer

    private func startFlushTimer() {
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in
            self?.flushSync()
        }
        timer.resume()
        flushTimer = timer
    }

    // MARK: - Lifecycle

    private func setupNotifications() {
        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        #endif
    }

    #if canImport(UIKit)
    @objc private func appDidEnterBackground() {
        let application = UIApplication.shared
        backgroundTaskId = application.beginBackgroundTask { [weak self] in
            // Expiration handler
            if let taskId = self?.backgroundTaskId, taskId != .invalid {
                application.endBackgroundTask(taskId)
                self?.backgroundTaskId = .invalid
            }
        }

        workQueue.async { [weak self] in
            guard let self else { return }
            self.flushSync()

            if self.backgroundTaskId != .invalid {
                application.endBackgroundTask(self.backgroundTaskId)
                self.backgroundTaskId = .invalid
            }
        }
    }
    #endif

    /// Current number of events in the in-memory queue.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return _events.count
    }

    deinit {
        flushTimer?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}
