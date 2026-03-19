import XCTest
@testable import StudioAnalytics

final class EventSerializationTests: XCTestCase {

    func testEventToJSON() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1710500000) // fixed timestamp
        let event = Event(
            id: id,
            appId: "test-app",
            event: "test.event",
            timestamp: date,
            properties: ["key": "value", "count": 42],
            context: ["sdk_version": "0.1.0"]
        )

        let json = event.toJSON()

        XCTAssertEqual(json["id"] as? String, id.uuidString)
        XCTAssertEqual(json["app_id"] as? String, "test-app")
        XCTAssertEqual(json["event"] as? String, "test.event")
        XCTAssertNotNil(json["timestamp"] as? String)

        let props = json["properties"] as? [String: Any]
        XCTAssertEqual(props?["key"] as? String, "value")
        XCTAssertEqual(props?["count"] as? Int, 42)

        let ctx = json["context"] as? [String: Any]
        XCTAssertEqual(ctx?["sdk_version"] as? String, "0.1.0")
    }

    func testEventRoundTrip() {
        let id = UUID()
        let date = Date(timeIntervalSince1970: 1710500000)
        let original = Event(
            id: id,
            appId: "test-app",
            event: "llm.request",
            timestamp: date,
            properties: ["tokens_in": 100, "tokens_out": 50, "model": "test-model"],
            context: ["app_version": "1.0.0"]
        )

        let json = original.toJSON()
        let restored = Event.fromJSON(json)

        XCTAssertNotNil(restored)
        XCTAssertEqual(restored?.id, id)
        XCTAssertEqual(restored?.appId, "test-app")
        XCTAssertEqual(restored?.event, "llm.request")

        let props = restored?.properties
        XCTAssertEqual(props?["tokens_in"] as? Int, 100)
        XCTAssertEqual(props?["tokens_out"] as? Int, 50)
        XCTAssertEqual(props?["model"] as? String, "test-model")
    }

    func testEventJSONDataSerialization() {
        let event = Event(
            appId: "test-app",
            event: "test.event",
            properties: ["key": "value"]
        )

        let data = event.toJSONData()
        XCTAssertNotNil(data)

        // Verify it's valid JSON
        if let data {
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertNotNil(parsed)
            XCTAssertEqual(parsed?["event"] as? String, "test.event")
        }
    }

    func testBatchSerialization() {
        let events = [
            Event(appId: "app", event: "event1", properties: [:]),
            Event(appId: "app", event: "event2", properties: ["x": 1])
        ]

        let batchJSON = events.toBatchJSON()
        let eventsArray = batchJSON["events"] as? [[String: Any]]
        XCTAssertEqual(eventsArray?.count, 2)

        let data = events.toBatchJSONData()
        XCTAssertNotNil(data)

        if let data {
            let restored = [Event].fromBatchJSON(data)
            XCTAssertEqual(restored?.count, 2)
            XCTAssertEqual(restored?[0].event, "event1")
            XCTAssertEqual(restored?[1].event, "event2")
        }
    }

    func testEventFromInvalidJSON() {
        // Missing required fields
        let badJSON: [String: Any] = ["foo": "bar"]
        let event = Event.fromJSON(badJSON)
        XCTAssertNil(event)
    }

    func testBatchFromInvalidData() {
        let badData = "not json".data(using: .utf8)!
        let events = [Event].fromBatchJSON(badData)
        XCTAssertNil(events)
    }

    func testLLMRequestProperties() {
        // Verify the trackLLMRequest helper builds correct property names.
        // We can't easily call the static method without configure, so we test
        // the property dictionary shape directly.
        let requestId = UUID()
        let conversationId = UUID()

        var props: [String: Any] = [
            "request_id": requestId.uuidString,
            "conversation_id": conversationId.uuidString,
            "call_type": "agent",
            "tokens_in": 3200,
            "tokens_out": 580,
            "model": "anthropic/claude-haiku-4.5",
            "cost_micros": Int64(6402),
            "latency_ms": 1850,
            "streaming": true,
            "turn_number": 2,
            "conversation_messages": 7,
            "tool_calls": ["create_entries", "update_memory", "update_layout"],
            "tool_call_count": 3,
            "action_count": 5,
            "parse_failure_count": 0,
            "has_text_response": false,
        ]
        props["ttft_ms"] = 290
        props["variant"] = "scanner"

        let event = Event(
            appId: "murmur-ios",
            event: "llm.request",
            properties: props,
            context: [:]
        )

        let json = event.toJSON()
        let jsonProps = json["properties"] as? [String: Any]

        XCTAssertEqual(jsonProps?["request_id"] as? String, requestId.uuidString)
        XCTAssertEqual(jsonProps?["conversation_id"] as? String, conversationId.uuidString)
        XCTAssertEqual(jsonProps?["call_type"] as? String, "agent")
        XCTAssertEqual(jsonProps?["tokens_in"] as? Int, 3200)
        XCTAssertEqual(jsonProps?["tokens_out"] as? Int, 580)
        XCTAssertEqual(jsonProps?["model"] as? String, "anthropic/claude-haiku-4.5")
        XCTAssertEqual(jsonProps?["cost_micros"] as? Int64, 6402)
        XCTAssertEqual(jsonProps?["latency_ms"] as? Int, 1850)
        XCTAssertEqual(jsonProps?["streaming"] as? Bool, true)
        XCTAssertEqual(jsonProps?["turn_number"] as? Int, 2)
        XCTAssertEqual(jsonProps?["conversation_messages"] as? Int, 7)
        XCTAssertEqual(jsonProps?["tool_call_count"] as? Int, 3)
        XCTAssertEqual(jsonProps?["action_count"] as? Int, 5)
        XCTAssertEqual(jsonProps?["parse_failure_count"] as? Int, 0)
        XCTAssertEqual(jsonProps?["has_text_response"] as? Bool, false)
        XCTAssertEqual(jsonProps?["ttft_ms"] as? Int, 290)
        XCTAssertEqual(jsonProps?["variant"] as? String, "scanner")

        let toolCalls = jsonProps?["tool_calls"] as? [String]
        XCTAssertEqual(toolCalls, ["create_entries", "update_memory", "update_layout"])
    }
}

final class EventQueueCapacityTests: XCTestCase {

    func testQueueDropsOldestWhenFull() {
        // Create a queue with a mock network client that never sends
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics-test-\(UUID().uuidString)")
        let persistence = Persistence(directory: tempDir)

        // We need a network client but it won't be used since we never flush
        let networkClient = NetworkClient(
            endpoint: URL(string: "http://localhost:9999")!,
            apiKey: "test"
        )
        let monitor = ConnectivityMonitor()

        let queue = EventQueue(
            persistence: persistence,
            networkClient: networkClient,
            connectivityMonitor: monitor
        )

        // Enqueue more than max capacity
        let maxSize = EventQueue.maxQueueSize
        for i in 0..<(maxSize + 100) {
            let event = Event(
                appId: "test",
                event: "test.\(i)",
                properties: [:]
            )
            queue.enqueue(event)
        }

        // Queue should be capped at maxQueueSize
        XCTAssertEqual(queue.count, maxSize)

        // Clean up
        try? FileManager.default.removeItem(at: tempDir)
    }
}

final class SessionTests: XCTestCase {

    func testFirstTouchCreatesSession() {
        var newSessionCalled = false
        let session = Session { _ in
            newSessionCalled = true
        }

        let id = session.touch()
        XCTAssertFalse(id.isEmpty)

        // Give async callback a moment
        let expectation = XCTestExpectation(description: "new session callback")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            XCTAssertTrue(newSessionCalled)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func testConsecutiveTouchesReturnSameSession() {
        let session = Session()

        let id1 = session.touch()
        let id2 = session.touch()
        let id3 = session.touch()

        XCTAssertEqual(id1, id2)
        XCTAssertEqual(id2, id3)
    }

    func testSessionIdAvailableAfterTouch() {
        let session = Session()
        XCTAssertNil(session.sessionId)

        let id = session.touch()
        XCTAssertEqual(session.sessionId, id)
    }
}

final class ConfigurationGatingTests: XCTestCase {

    func testEventsDroppedBeforeConfigure() {
        // This test verifies that tracking before configure doesn't crash.
        // Since events are silently dropped, we just verify no crash occurs.
        // We use a fresh track call — the singleton might already be configured
        // from another test, but the important thing is no crash.
        StudioAnalytics.track("should.be.dropped", properties: ["test": true])
        // If we get here without crashing, the test passes.
    }
}

final class PersistenceTests: XCTestCase {

    private var tempDir: URL!
    private var persistence: Persistence!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("analytics-test-\(UUID().uuidString)")
        persistence = Persistence(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testWriteAndLoadBatch() {
        let events = [
            Event(appId: "test", event: "e1", properties: ["k": "v"]),
            Event(appId: "test", event: "e2", properties: ["n": 42])
        ]

        let filename = persistence.writeBatch(events)
        XCTAssertNotNil(filename)

        let loaded = persistence.loadAllBatches()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.events.count, 2)
        XCTAssertEqual(loaded.first?.events[0].event, "e1")
        XCTAssertEqual(loaded.first?.events[1].event, "e2")
    }

    func testDeleteBatch() {
        let events = [Event(appId: "test", event: "e1")]
        let filename = persistence.writeBatch(events)!

        persistence.deleteBatch(filename: filename)

        let loaded = persistence.loadAllBatches()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testCorruptFileIsDeleted() {
        // Write a corrupt file manually
        let corruptFile = tempDir.appendingPathComponent("batch-corrupt.json")
        try? "not valid json {{{".data(using: .utf8)?.write(to: corruptFile)

        let loaded = persistence.loadAllBatches()
        XCTAssertTrue(loaded.isEmpty)

        // Verify the corrupt file was deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptFile.path))
    }

    func testEmptyBatchNotWritten() {
        let result = persistence.writeBatch([])
        XCTAssertNil(result)
    }

    func testDeleteAll() {
        persistence.writeBatch([Event(appId: "test", event: "e1")])
        persistence.writeBatch([Event(appId: "test", event: "e2")])

        var loaded = persistence.loadAllBatches()
        XCTAssertEqual(loaded.count, 2)

        persistence.deleteAll()

        loaded = persistence.loadAllBatches()
        XCTAssertTrue(loaded.isEmpty)
    }
}
