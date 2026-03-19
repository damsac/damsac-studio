import Foundation
#if canImport(UIKit)
import UIKit
#endif
import CommonCrypto

/// Gathers device and app context to attach to every event.
final class DeviceContext: @unchecked Sendable {
    static let sdkVersion = "0.1.0"

    private let appId: String
    private var cachedContext: [String: Any]?
    private let lock = NSLock()

    init(appId: String) {
        self.appId = appId
    }

    /// Returns the context dictionary to be attached to every event.
    func context(sessionId: String) -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }

        if cachedContext == nil {
            cachedContext = buildContext()
        }

        var ctx = cachedContext ?? [:]
        ctx["session_id"] = sessionId
        return ctx
    }

    private func buildContext() -> [String: Any] {
        var ctx: [String: Any] = [
            "sdk_version": Self.sdkVersion,
            "os_version": osVersion(),
            "device_model": deviceModel(),
            "locale": Locale.current.identifier,
            "timezone": TimeZone.current.identifier
        ]

        if let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            ctx["app_version"] = appVersion
        }
        if let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String {
            ctx["build_number"] = buildNumber
        }

        let deviceId = hashedDeviceId()
        if let deviceId {
            ctx["device_id"] = deviceId
        }

        return ctx
    }

    private func osVersion() -> String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    private func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let mirror = Mirror(reflecting: systemInfo.machine)
        let machine = mirror.children.reduce("") { acc, child in
            guard let value = child.value as? Int8, value != 0 else { return acc }
            return acc + String(UnicodeScalar(UInt8(value)))
        }
        return machine
    }

    /// IDFV hashed with SHA-256, salted with appId.
    /// Returns nil in contexts where IDFV is unavailable (e.g., app extensions, tests).
    private func hashedDeviceId() -> String? {
        #if canImport(UIKit) && !targetEnvironment(simulator) || canImport(UIKit) && targetEnvironment(simulator)
        guard let idfv = UIDevice.current.identifierForVendor?.uuidString else {
            return nil
        }
        let saltedInput = "\(appId):\(idfv)"
        return sha256(saltedInput)
        #else
        return nil
        #endif
    }

    private func sha256(_ input: String) -> String {
        guard let data = input.data(using: .utf8) else { return "" }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
