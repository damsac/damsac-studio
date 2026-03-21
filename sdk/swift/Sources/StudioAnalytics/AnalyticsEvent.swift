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
