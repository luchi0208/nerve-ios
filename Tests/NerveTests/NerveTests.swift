#if DEBUG

import XCTest
@testable import Nerve
import NerveObjC

// MARK: - Navigation Map Tests

final class NavigationMapTests: XCTestCase {

    var map: NerveNavigationMap!

    override func setUp() {
        map = NerveNavigationMap()
    }

    func testRecordTransition() {
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")

        XCTAssertTrue(map.screens.contains("HomeVC"))
        XCTAssertTrue(map.screens.contains("SettingsVC"))
        XCTAssertEqual(map.edges["HomeVC"]?.count, 1)
        XCTAssertEqual(map.edges["HomeVC"]?.first?.to, "SettingsVC")
        XCTAssertEqual(map.edges["HomeVC"]?.first?.action, "push")
        XCTAssertEqual(map.edges["HomeVC"]?.first?.visitCount, 1)
    }

    func testDuplicateTransitionIncrementsVisitCount() {
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")

        XCTAssertEqual(map.edges["HomeVC"]?.count, 1)
        XCTAssertEqual(map.edges["HomeVC"]?.first?.visitCount, 3)
    }

    func testDifferentActionsCreateSeparateEdges() {
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "present")

        XCTAssertEqual(map.edges["HomeVC"]?.count, 2)
    }

    func testAppearUpdatesCurrentScreen() {
        map.recordTransition(from: "", to: "HomeVC", action: "appear")
        XCTAssertEqual(map.currentScreen, "HomeVC")

        map.recordTransition(from: "", to: "SettingsVC", action: "appear")
        XCTAssertEqual(map.currentScreen, "SettingsVC")
    }

    func testFindPathSimple() {
        map.recordTransition(from: "", to: "HomeVC", action: "appear")
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")
        map.recordTransition(from: "SettingsVC", to: "ProfileVC", action: "push")

        let path = map.findPath(to: "ProfileVC")
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.count, 2)
        XCTAssertEqual(path?[0].to, "SettingsVC")
        XCTAssertEqual(path?[1].to, "ProfileVC")
    }

    func testFindPathAlreadyThere() {
        map.recordTransition(from: "", to: "HomeVC", action: "appear")
        let path = map.findPath(to: "HomeVC")
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.count, 0)
    }

    func testFindPathNoPath() {
        map.recordTransition(from: "", to: "HomeVC", action: "appear")
        map.recordTransition(from: "SettingsVC", to: "ProfileVC", action: "push")

        let path = map.findPath(to: "ProfileVC")
        XCTAssertNil(path)
    }

    func testFindPathBFS() {
        // Build a graph: Home → A → C, Home → B → C
        // BFS should find shortest path (Home → A → C or Home → B → C, both length 2)
        map.recordTransition(from: "", to: "Home", action: "appear")
        map.recordTransition(from: "Home", to: "A", action: "push")
        map.recordTransition(from: "A", to: "C", action: "push")
        map.recordTransition(from: "Home", to: "B", action: "tab")
        map.recordTransition(from: "B", to: "C", action: "push")

        let path = map.findPath(to: "C")
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.count, 2)
    }

    func testLastTappedElementRecording() {
        map.lastTappedElement = (label: "Settings", identifier: "settings-btn")
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")

        XCTAssertEqual(map.edges["HomeVC"]?.first?.element, "Settings")
        XCTAssertEqual(map.edges["HomeVC"]?.first?.elementId, "settings-btn")
        XCTAssertNil(map.lastTappedElement) // Consumed
    }

    func testMarkScreenRequiresInput() {
        map.recordTransition(from: "HomeVC", to: "LoginVC", action: "push")
        map.markScreenRequiresInput("LoginVC", fields: ["email-field", "password-field"])

        let edge = map.edges["HomeVC"]?.first
        XCTAssertTrue(edge?.requiresInput ?? false)
        XCTAssertEqual(edge?.inputFields, ["email-field", "password-field"])
    }

    func testJSONRoundTrip() {
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")
        map.recordTransition(from: "SettingsVC", to: "ProfileVC", action: "push")

        let json = map.toJSON()
        XCTAssertFalse(json.isEmpty)

        let newMap = NerveNavigationMap()
        newMap.loadJSON(json)

        XCTAssertTrue(newMap.screens.contains("HomeVC"))
        XCTAssertTrue(newMap.screens.contains("SettingsVC"))
        XCTAssertTrue(newMap.screens.contains("ProfileVC"))
        XCTAssertEqual(newMap.edges["HomeVC"]?.count, 1)
        XCTAssertEqual(newMap.edges["SettingsVC"]?.count, 1)
    }

    func testDescribeEmpty() {
        let desc = map.describe()
        XCTAssertTrue(desc.contains("empty"))
    }

    func testDescribeWithData() {
        map.recordTransition(from: "", to: "HomeVC", action: "appear")
        map.recordTransition(from: "HomeVC", to: "SettingsVC", action: "push")

        let desc = map.describe()
        XCTAssertTrue(desc.contains("screens: 2"))
        XCTAssertTrue(desc.contains("HomeVC"))
        XCTAssertTrue(desc.contains("SettingsVC"))
    }
}

// MARK: - Network Store Tests

final class NetworkStoreTests: XCTestCase {

    var store: NerveNetworkStore!

    override func setUp() {
        // Use a fresh instance for each test
        store = NerveNetworkStore()
    }

    func testRecordTransaction() {
        let tx = NerveNetworkStore.Transaction(
            id: "1", method: "GET", urlString: "/api/users", startTime: Date()
        )
        store.record(tx)
        XCTAssertEqual(store.count, 1)
    }

    func testUpdateTransaction() {
        let tx = NerveNetworkStore.Transaction(
            id: "tx1", method: "POST", urlString: "/api/orders", startTime: Date()
        )
        store.record(tx)
        store.update(id: "tx1", statusCode: 201, bodySize: 512)

        let recent = store.recent(limit: 1)
        XCTAssertEqual(recent.first?.statusCode, 201)
        XCTAssertEqual(recent.first?.responseBodySize, 512)
        XCTAssertNotNil(recent.first?.endTime)
    }

    func testPendingCount() {
        let tx1 = NerveNetworkStore.Transaction(
            id: "1", method: "GET", urlString: "/api/a", startTime: Date()
        )
        let tx2 = NerveNetworkStore.Transaction(
            id: "2", method: "GET", urlString: "/api/b", startTime: Date()
        )
        store.record(tx1)
        store.record(tx2)

        XCTAssertEqual(store.pendingCount, 2)

        store.update(id: "1", statusCode: 200, bodySize: 100)
        XCTAssertEqual(store.pendingCount, 1)

        store.update(id: "2", statusCode: 200, bodySize: 200)
        XCTAssertEqual(store.pendingCount, 0)
    }

    func testRecentWithFilter() {
        store.record(NerveNetworkStore.Transaction(
            id: "1", method: "GET", urlString: "/api/users", startTime: Date()
        ))
        store.record(NerveNetworkStore.Transaction(
            id: "2", method: "POST", urlString: "/api/orders", startTime: Date()
        ))
        store.record(NerveNetworkStore.Transaction(
            id: "3", method: "GET", urlString: "/api/users/123", startTime: Date()
        ))

        let filtered = store.recent(limit: 10, urlFilter: "users")
        XCTAssertEqual(filtered.count, 2)
    }

    func testRecentLimit() {
        for i in 0..<20 {
            store.record(NerveNetworkStore.Transaction(
                id: "\(i)", method: "GET", urlString: "/api/\(i)", startTime: Date()
            ))
        }

        let recent = store.recent(limit: 5)
        XCTAssertEqual(recent.count, 5)
        // Should be the last 5
        XCTAssertEqual(recent.first?.urlString, "/api/15")
    }
}

// MARK: - Console Tests

final class ConsoleTests: XCTestCase {

    func testAddAndRetrieveLogs() {
        let console = NerveConsole()
        console.addLog("Hello", level: .info)
        console.addLog("World", level: .debug)
        console.addLog("Error!", level: .error)

        let logs = console.recentLogs(limit: 10)
        XCTAssertEqual(logs.count, 3)
        XCTAssertEqual(logs[0].message, "Hello")
        XCTAssertEqual(logs[0].level, .info)
        XCTAssertEqual(logs[2].message, "Error!")
        XCTAssertEqual(logs[2].level, .error)
    }

    func testLogRingBuffer() {
        let console = NerveConsole()
        for i in 0..<1100 {
            console.addLog("Log \(i)", level: .info)
        }

        XCTAssertEqual(console.totalCount, 1000) // Capped at maxLogs
        let logs = console.recentLogs(limit: 5)
        // Should be the last 5 (1095-1099)
        XCTAssertEqual(logs.last?.message, "Log 1099")
    }

    func testLogLevelPriority() {
        XCTAssertTrue(NerveConsole.LogLevel.error.priority > NerveConsole.LogLevel.warning.priority)
        XCTAssertTrue(NerveConsole.LogLevel.warning.priority > NerveConsole.LogLevel.info.priority)
        XCTAssertTrue(NerveConsole.LogLevel.info.priority > NerveConsole.LogLevel.debug.priority)
    }

    func testFormattedTimestamp() {
        let console = NerveConsole()
        console.addLog("test", level: .info)
        let log = console.recentLogs(limit: 1).first!
        // Should be HH:mm:ss.SSS format
        XCTAssertTrue(log.formattedTimestamp.count >= 10) // "12:34:56.789"
    }
}

// MARK: - Command Parsing Tests

final class CommandParsingTests: XCTestCase {

    func testDecodeCommand() throws {
        let json = """
        {"id":"req_1","command":"view","params":{}}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(NerveCommand.self, from: json)
        XCTAssertEqual(command.id, "req_1")
        XCTAssertEqual(command.command, "view")
    }

    func testDecodeCommandWithParams() throws {
        let json = """
        {"id":"req_2","command":"tap","params":{"query":"#save-btn"}}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(NerveCommand.self, from: json)
        XCTAssertEqual(command.stringParam("query"), "#save-btn")
    }

    func testDecodeCommandWithTypedParams() throws {
        let json = """
        {"id":"req_3","command":"scroll","params":{"direction":"down","amount":500}}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(NerveCommand.self, from: json)
        XCTAssertEqual(command.stringParam("direction"), "down")
        XCTAssertEqual(command.intParam("amount"), 500)
        XCTAssertEqual(command.doubleParam("amount"), 500.0)
    }

    func testDecodeCommandWithBoolParam() throws {
        let json = """
        {"id":"req_4","command":"type","params":{"text":"hello","submit":true}}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(NerveCommand.self, from: json)
        XCTAssertEqual(command.stringParam("text"), "hello")
        XCTAssertEqual(command.boolParam("submit"), true)
    }

    func testMissingParam() throws {
        let json = """
        {"id":"req_5","command":"view","params":{}}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(NerveCommand.self, from: json)
        XCTAssertNil(command.stringParam("nonexistent"))
        XCTAssertNil(command.intParam("nonexistent"))
    }

    func testNullParams() throws {
        let json = """
        {"id":"req_6","command":"status"}
        """.data(using: .utf8)!

        let command = try JSONDecoder().decode(NerveCommand.self, from: json)
        XCTAssertNil(command.params)
        XCTAssertNil(command.stringParam("anything"))
    }
}

// MARK: - Response Formatting Tests

final class ResponseFormattingTests: XCTestCase {

    func testSuccessResponse() {
        let response = NerveResponse.success("req_1", "Hello world")
        XCTAssertTrue(response.ok)
        XCTAssertEqual(response.id, "req_1")

        let json = response.toJSON()
        XCTAssertTrue(json.contains("\"ok\":true"))
        XCTAssertTrue(json.contains("\"id\":\"req_1\""))
        XCTAssertTrue(json.contains("Hello world"))
    }

    func testErrorResponse() {
        let response = NerveResponse.error("req_2", "Not found")
        XCTAssertFalse(response.ok)

        let json = response.toJSON()
        XCTAssertTrue(json.contains("\"ok\":false"))
        XCTAssertTrue(json.contains("Not found"))
    }

    func testResponseEscaping() {
        let response = NerveResponse.success("req_3", "line1\nline2\ttab\"quote")
        let json = response.toJSON()
        XCTAssertTrue(json.contains("\\n"))
        XCTAssertTrue(json.contains("\\t"))
        XCTAssertTrue(json.contains("\\\""))
    }
}

// MARK: - ObjC Bridge Tests

final class ObjCBridgeTests: XCTestCase {

    func testClassNameForObjCObject() {
        let label = UILabel()
        let name = NerveClassName(label)
        XCTAssertEqual(name, "UILabel")
    }

    func testClassNameForNSObject() {
        let obj = NSObject()
        let name = NerveClassName(obj)
        XCTAssertEqual(name, "NSObject")
    }

    func testReadPropertyKVC() {
        let label = UILabel()
        label.text = "Hello"
        let value = NerveReadProperty(label, "text") as? String
        XCTAssertEqual(value, "Hello")
    }

    func testReadPropertyInvalid() {
        let obj = NSObject()
        let value = NerveReadProperty(obj, "nonexistent.keypath")
        XCTAssertNil(value)
    }

    func testViewControllerForView() {
        let vc = UIViewController()
        _ = vc.view // Load view
        let found = NerveViewControllerForView(vc.view)
        XCTAssertEqual(found, vc)
    }

    func testPointerValidation() {
        let obj = NSObject()
        let ptr = Unmanaged.passUnretained(obj).toOpaque()
        XCTAssertTrue(NervePointerIsValidObject(ptr))
        XCTAssertFalse(NervePointerIsValidObject(UnsafeRawPointer(bitPattern: 0x1)!))
    }
}

// MARK: - NerveNavEdge Codable Tests

final class NavEdgeCodableTests: XCTestCase {

    func testEncodeDecode() throws {
        let edge = NerveNavEdge(
            from: "A", to: "B", action: "push",
            element: "Settings", elementId: "settings-btn",
            requiresInput: false, inputFields: [],
            visitCount: 3
        )

        let data = try JSONEncoder().encode(edge)
        let decoded = try JSONDecoder().decode(NerveNavEdge.self, from: data)

        XCTAssertEqual(decoded.from, "A")
        XCTAssertEqual(decoded.to, "B")
        XCTAssertEqual(decoded.action, "push")
        XCTAssertEqual(decoded.element, "Settings")
        XCTAssertEqual(decoded.elementId, "settings-btn")
        XCTAssertEqual(decoded.visitCount, 3)
    }
}

#endif
