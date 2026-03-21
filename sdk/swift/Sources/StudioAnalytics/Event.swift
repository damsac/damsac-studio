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
