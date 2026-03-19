import Foundation

/// HTTP client for sending event batches to the analytics server.
///
/// - POST to `{endpoint}/v1/events` with `X-API-Key` header
/// - 2xx: success
/// - 4xx: drop (not retryable)
/// - 5xx/timeout: exponential backoff 1s -> 60s cap
/// - Circuit breaker: 5 consecutive failures -> pause 60s
final class NetworkClient: @unchecked Sendable {

    enum SendResult {
        case success
        case clientError(statusCode: Int)  // 4xx — drop events
        case serverError(statusCode: Int)  // 5xx — retry later
        case networkError(Error)           // timeout/connectivity — retry later
        case circuitOpen                   // too many failures, pausing
    }

    private let endpoint: URL
    private let apiKey: String
    private let session: URLSession
    private let lock = NSLock()

    // Exponential backoff state
    private var _currentBackoff: TimeInterval = 0
    private let minBackoff: TimeInterval = 1.0
    private let maxBackoff: TimeInterval = 60.0
    private var _lastFailureTime: Date?

    // Circuit breaker state
    private var _consecutiveFailures: Int = 0
    private let circuitBreakerThreshold: Int = 5
    private let circuitBreakerPause: TimeInterval = 60.0
    private var _circuitOpenedAt: Date?

    init(endpoint: URL, apiKey: String) {
        self.endpoint = endpoint
        self.apiKey = apiKey

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    /// Send a batch of events synchronously. Blocks the calling thread until complete.
    func sendSync(batchData: Data) -> SendResult {
        // Check circuit breaker
        lock.lock()
        if let openedAt = _circuitOpenedAt {
            if Date().timeIntervalSince(openedAt) < circuitBreakerPause {
                lock.unlock()
                return .circuitOpen
            }
            // Reset circuit breaker after pause
            _circuitOpenedAt = nil
            _consecutiveFailures = 0
        }

        // Check backoff
        if let lastFailure = _lastFailureTime, _currentBackoff > 0 {
            let elapsed = Date().timeIntervalSince(lastFailure)
            if elapsed < _currentBackoff {
                lock.unlock()
                return .serverError(statusCode: 0) // Still in backoff
            }
        }
        lock.unlock()

        let url = endpoint.appendingPathComponent("v1/events")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("StudioAnalytics/\(DeviceContext.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = batchData

        let semaphore = DispatchSemaphore(value: 0)
        var sendResult: SendResult = .networkError(URLError(.unknown))

        let task = session.dataTask(with: request) { [weak self] _, response, error in
            defer { semaphore.signal() }

            if let error {
                self?.recordFailure()
                sendResult = .networkError(error)
                return
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                self?.recordFailure()
                sendResult = .networkError(URLError(.badServerResponse))
                return
            }

            let statusCode = httpResponse.statusCode

            switch statusCode {
            case 200...299:
                self?.recordSuccess()
                sendResult = .success

            case 400...499:
                // Client errors are not retryable — reset backoff since
                // the server is reachable, but drop the events
                self?.recordSuccess()
                sendResult = .clientError(statusCode: statusCode)

            default:
                // 5xx and other server errors
                self?.recordFailure()
                sendResult = .serverError(statusCode: statusCode)
            }
        }
        task.resume()
        semaphore.wait()

        return sendResult
    }

    private func recordSuccess() {
        lock.lock()
        _consecutiveFailures = 0
        _currentBackoff = 0
        _lastFailureTime = nil
        _circuitOpenedAt = nil
        lock.unlock()
    }

    private func recordFailure() {
        lock.lock()
        _consecutiveFailures += 1
        _lastFailureTime = Date()

        // Exponential backoff
        if _currentBackoff == 0 {
            _currentBackoff = minBackoff
        } else {
            _currentBackoff = min(_currentBackoff * 2, maxBackoff)
        }

        // Circuit breaker
        if _consecutiveFailures >= circuitBreakerThreshold {
            _circuitOpenedAt = Date()
        }
        lock.unlock()
    }

    /// Reset backoff and circuit breaker state. Used when connectivity is restored.
    func resetBackoff() {
        lock.lock()
        _currentBackoff = 0
        _lastFailureTime = nil
        // Don't reset circuit breaker — let it expire naturally
        lock.unlock()
    }
}
