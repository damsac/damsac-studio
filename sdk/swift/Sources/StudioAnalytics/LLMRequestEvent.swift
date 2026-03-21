import Foundation

/// Tracks an LLM API request. This is an SDK-provided event type since
/// LLM cost/latency tracking is a studio-level concern shared across apps.
public struct LLMRequestEvent: AnalyticsEvent {
    public static let eventName = "llm.request"

    public var requestId: UUID
    public var conversationId: UUID
    public var callType: String
    public var tokensIn: Int
    public var tokensOut: Int
    public var model: String
    public var costMicros: Int64
    public var latencyMs: Int
    public var streaming: Bool
    public var turnNumber: Int
    public var conversationMessages: Int
    public var toolCalls: [String]
    public var actionCount: Int
    public var parseFailureCount: Int
    public var hasTextResponse: Bool
    public var ttftMs: Int?
    public var variant: String?
    public var itemsCount: Int?
    public var error: String?
    public var errorStatusCode: Int?

    public init(
        requestId: UUID,
        conversationId: UUID,
        callType: String,
        tokensIn: Int,
        tokensOut: Int,
        model: String,
        costMicros: Int64,
        latencyMs: Int,
        streaming: Bool,
        turnNumber: Int,
        conversationMessages: Int,
        toolCalls: [String],
        actionCount: Int,
        parseFailureCount: Int,
        hasTextResponse: Bool
    ) {
        self.requestId = requestId
        self.conversationId = conversationId
        self.callType = callType
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.model = model
        self.costMicros = costMicros
        self.latencyMs = latencyMs
        self.streaming = streaming
        self.turnNumber = turnNumber
        self.conversationMessages = conversationMessages
        self.toolCalls = toolCalls
        self.actionCount = actionCount
        self.parseFailureCount = parseFailureCount
        self.hasTextResponse = hasTextResponse
    }

    // MARK: - Encoding
    // Explicit CodingKeys for snake_case wire format.
    // Custom encode(to:) emits the derived `tool_call_count` field.

    enum CodingKeys: String, CodingKey {
        case requestId = "request_id"
        case conversationId = "conversation_id"
        case callType = "call_type"
        case tokensIn = "tokens_in"
        case tokensOut = "tokens_out"
        case model
        case costMicros = "cost_micros"
        case latencyMs = "latency_ms"
        case streaming
        case turnNumber = "turn_number"
        case conversationMessages = "conversation_messages"
        case toolCalls = "tool_calls"
        case toolCallCount = "tool_call_count"
        case actionCount = "action_count"
        case parseFailureCount = "parse_failure_count"
        case hasTextResponse = "has_text_response"
        case ttftMs = "ttft_ms"
        case variant
        case itemsCount = "items_count"
        case error
        case errorStatusCode = "error_status_code"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        // Encode UUIDs as uppercase strings to match existing wire format
        try c.encode(requestId.uuidString, forKey: .requestId)
        try c.encode(conversationId.uuidString, forKey: .conversationId)
        try c.encode(callType, forKey: .callType)
        try c.encode(tokensIn, forKey: .tokensIn)
        try c.encode(tokensOut, forKey: .tokensOut)
        try c.encode(model, forKey: .model)
        try c.encode(costMicros, forKey: .costMicros)
        try c.encode(latencyMs, forKey: .latencyMs)
        try c.encode(streaming, forKey: .streaming)
        try c.encode(turnNumber, forKey: .turnNumber)
        try c.encode(conversationMessages, forKey: .conversationMessages)
        try c.encode(toolCalls, forKey: .toolCalls)
        try c.encode(toolCalls.count, forKey: .toolCallCount)
        try c.encode(actionCount, forKey: .actionCount)
        try c.encode(parseFailureCount, forKey: .parseFailureCount)
        try c.encode(hasTextResponse, forKey: .hasTextResponse)
        try c.encodeIfPresent(ttftMs, forKey: .ttftMs)
        try c.encodeIfPresent(variant, forKey: .variant)
        try c.encodeIfPresent(itemsCount, forKey: .itemsCount)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(errorStatusCode, forKey: .errorStatusCode)
    }
}
