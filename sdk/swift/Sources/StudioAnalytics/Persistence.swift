import Foundation

/// Persists event batches as JSON files on disk.
///
/// - Storage location: `Library/Application Support/analytics/`
/// - One JSON file per flush batch
/// - 5MB disk cap, oldest deleted when exceeded
/// - Corrupt files are deleted on read
final class Persistence: @unchecked Sendable {
    /// Maximum total disk usage for batch files.
    static let maxDiskBytes: UInt64 = 5 * 1024 * 1024 // 5MB

    private let directory: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = appSupport.appendingPathComponent("analytics", isDirectory: true)
        }
        ensureDirectoryExists()
    }

    // MARK: - Write

    /// Write a batch of events to disk. Returns the filename on success.
    @discardableResult
    func writeBatch(_ events: [Event]) -> String? {
        lock.lock()
        defer { lock.unlock() }

        guard !events.isEmpty else { return nil }

        let payload = events.toBatchJSON()
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            return nil
        }

        // Enforce disk cap before writing
        enforceDiskCapLocked(reserving: UInt64(data.count))

        let filename = "batch-\(UUID().uuidString).json"
        let fileURL = directory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL, options: .atomic)
            return filename
        } catch {
            return nil
        }
    }

    // MARK: - Read

    /// Load all persisted batches from disk. Returns array of (filename, events) tuples.
    /// Corrupt files are deleted.
    func loadAllBatches() -> [(filename: String, events: [Event])] {
        lock.lock()
        defer { lock.unlock() }

        var results: [(String, [Event])] = []

        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return results
        }

        // Sort by creation date (oldest first)
        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lhsDate < rhsDate
            }

        for fileURL in sorted {
            do {
                let data = try Data(contentsOf: fileURL)
                if let events = [Event].fromBatchJSON(data), !events.isEmpty {
                    results.append((fileURL.lastPathComponent, events))
                } else {
                    // Corruption recovery: delete unreadable files
                    try? fileManager.removeItem(at: fileURL)
                }
            } catch {
                // Corruption recovery: delete unreadable files
                try? fileManager.removeItem(at: fileURL)
            }
        }

        return results
    }

    // MARK: - Delete

    /// Delete a specific batch file after successful upload.
    func deleteBatch(filename: String) {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = directory.appendingPathComponent(filename)
        try? fileManager.removeItem(at: fileURL)
    }

    /// Delete all batch files.
    func deleteAll() {
        lock.lock()
        defer { lock.unlock() }

        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files where file.pathExtension == "json" {
            try? fileManager.removeItem(at: file)
        }
    }

    // MARK: - Disk Management

    /// Total size of all batch files in bytes.
    func totalDiskUsage() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalDiskUsageLocked()
    }

    private func totalDiskUsageLocked() -> UInt64 {
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        return files
            .filter { $0.pathExtension == "json" }
            .reduce(UInt64(0)) { total, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return total + UInt64(size)
            }
    }

    /// Delete oldest batch files until disk usage is under the cap.
    /// Must be called while holding the lock.
    private func enforceDiskCapLocked(reserving additionalBytes: UInt64 = 0) {
        var currentUsage = totalDiskUsageLocked() + additionalBytes
        guard currentUsage > Self.maxDiskBytes else { return }

        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let sorted = files
            .filter { $0.pathExtension == "json" }
            .sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return lhsDate < rhsDate
            }

        for fileURL in sorted {
            guard currentUsage > Self.maxDiskBytes else { break }
            let fileSize = UInt64((try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            try? fileManager.removeItem(at: fileURL)
            currentUsage -= fileSize
        }
    }

    // MARK: - Helpers

    private func ensureDirectoryExists() {
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
