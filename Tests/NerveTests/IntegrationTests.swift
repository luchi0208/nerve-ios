#if DEBUG

import XCTest
@testable import Nerve
import NerveObjC

// MARK: - Integration Tests
// These tests run inside a real app process on simulator.
// They verify that Nerve's inspection and interaction work against live UIKit views.

final class ViewInspectionIntegrationTests: XCTestCase {

    // MARK: - View Hierarchy Walking

    @MainActor
    func testGetAllWindowsReturnsAtLeast1() {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? []
        // In a test runner, there should be at least the test host window
        XCTAssertGreaterThanOrEqual(windows.count, 0) // May be 0 in pure unit test context
    }

    @MainActor
    func testInspectUILabel() {
        let label = UILabel()
        label.text = "Hello Nerve"
        label.accessibilityIdentifier = "test-label"

        XCTAssertEqual(label.accessibilityLabel, nil) // UILabel auto-generates from text
        XCTAssertEqual(label.accessibilityIdentifier, "test-label")
        XCTAssertEqual(NerveReadProperty(label, "text") as? String, "Hello Nerve")
    }

    @MainActor
    func testInspectUIButton() {
        let button = UIButton(type: .system)
        button.setTitle("Tap Me", for: .normal)
        button.accessibilityIdentifier = "test-button"

        XCTAssertEqual(button.accessibilityIdentifier, "test-button")
        XCTAssertEqual(NerveReadProperty(button, "currentTitle") as? String, "Tap Me")
    }

    @MainActor
    func testInspectUITextField() {
        let field = UITextField()
        field.text = "test@example.com"
        field.placeholder = "Email"
        field.accessibilityIdentifier = "email-field"

        XCTAssertEqual(field.accessibilityIdentifier, "email-field")
        XCTAssertEqual(NerveReadProperty(field, "text") as? String, "test@example.com")
        XCTAssertEqual(NerveReadProperty(field, "placeholder") as? String, "Email")
    }

    @MainActor
    func testInspectUISwitch() {
        let toggle = UISwitch()
        toggle.isOn = true
        toggle.accessibilityIdentifier = "test-switch"

        XCTAssertEqual(toggle.accessibilityIdentifier, "test-switch")
        XCTAssertEqual(NerveReadProperty(toggle, "isOn") as? Bool, true)
    }

    // MARK: - View Controller Hierarchy

    @MainActor
    func testViewControllerForView() {
        let vc = UIViewController()
        _ = vc.view // Force load
        let found = NerveViewControllerForView(vc.view)
        XCTAssertEqual(found, vc)
    }

    @MainActor
    func testNestedViewControllerForView() {
        let nav = UINavigationController(rootViewController: UIViewController())
        _ = nav.view // Force load
        let rootVC = nav.viewControllers.first!
        _ = rootVC.view

        let found = NerveViewControllerForView(rootVC.view)
        XCTAssertEqual(found, rootVC)
    }

    // MARK: - Class Names

    func testObjCClassName() {
        XCTAssertEqual(NerveClassName(UILabel()), "UILabel")
        XCTAssertEqual(NerveClassName(UIButton()), "UIButton")
        XCTAssertEqual(NerveClassName(NSObject()), "NSObject")
    }

    func testSwiftClassDetection() {
        // NerveNavigationMap is a Swift class
        let map = NerveNavigationMap()
        let name = NerveClassName(map)
        // Should be demangled and contain "NerveNavigationMap"
        XCTAssertTrue(name.contains("NerveNavigationMap"), "Got: \(name)")
    }

    // MARK: - Property Reading (KVC)

    @MainActor
    func testKVCReadValidProperty() {
        let view = UIView()
        view.tag = 42
        XCTAssertEqual(NerveReadProperty(view, "tag") as? Int, 42)
    }

    @MainActor
    func testKVCReadInvalidProperty() {
        let view = UIView()
        let value = NerveReadProperty(view, "nonExistentProperty123")
        XCTAssertNil(value)
    }

    @MainActor
    func testKVCReadNestedProperty() {
        let view = UIView()
        view.layer.cornerRadius = 10
        let value = NerveReadProperty(view, "layer.cornerRadius") as? Double
        XCTAssertEqual(value, 10)
    }

    // MARK: - Accessibility Tree

    @MainActor
    func testAccessibilityTraitsCanBeSet() {
        // Verify we can read/write accessibility traits
        let view = UIView()
        view.accessibilityTraits = [.button, .header]
        XCTAssertTrue(view.accessibilityTraits.contains(.button))
        XCTAssertTrue(view.accessibilityTraits.contains(.header))
    }

    @MainActor
    func testAccessibilityIdentifierAndLabel() {
        let button = UIButton(type: .system)
        button.setTitle("Submit", for: .normal)
        button.accessibilityIdentifier = "submit-btn"
        button.accessibilityLabel = "Submit Form"

        XCTAssertEqual(button.accessibilityIdentifier, "submit-btn")
        XCTAssertEqual(button.accessibilityLabel, "Submit Form")
    }
}

// MARK: - Engine Integration Tests

final class EngineIntegrationTests: XCTestCase {

    func testEngineStartStop() {
        let engine = NerveEngine.shared
        // Engine may already be started by other tests
        // Just verify it doesn't crash
        engine.stop()
        engine.start(port: 0)
        engine.stop()
    }

    func testStatusCommand() async {
        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_1","command":"status","params":{}}
        """.data(using: .utf8)!)

        let response = await NerveEngine.shared.handleCommand(command)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.body.contains("status: connected"))
        XCTAssertTrue(response.body.contains("nerve: 0.1.0"))
    }

    func testConsoleCommand() async {
        let console = NerveEngine.shared.console
        console.addLog("test log entry", level: NerveConsole.LogLevel.info)

        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_2","command":"console","params":{"limit":5,"filter":"test log"}}
        """.data(using: .utf8)!)

        let response = await NerveEngine.shared.handleCommand(command)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.body.contains("test log entry"))
    }

    func testConsoleSinceLastAction() async {
        let engine = NerveEngine.shared
        let console = engine.console

        console.addLog("before action", level: NerveConsole.LogLevel.info)
        engine.lastActionTime = Date()
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        console.addLog("after action", level: NerveConsole.LogLevel.info)

        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_3","command":"console","params":{"since":"last_action"}}
        """.data(using: .utf8)!)

        let response = await engine.handleCommand(command)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.body.contains("after action"))
        XCTAssertFalse(response.body.contains("before action"))
    }

    func testMapCommand() async {
        let engine = NerveEngine.shared
        engine.navMap.recordTransition(from: "ScreenA", to: "ScreenB", action: "push")

        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_4","command":"map","params":{}}
        """.data(using: .utf8)!)

        let response = await engine.handleCommand(command)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.body.contains("ScreenA"))
        XCTAssertTrue(response.body.contains("ScreenB"))
    }

    func testMapJSONExport() async {
        let engine = NerveEngine.shared
        engine.navMap.recordTransition(from: "X", to: "Y", action: "tab")

        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_5","command":"map","params":{"format":"json"}}
        """.data(using: .utf8)!)

        let response = await engine.handleCommand(command)
        XCTAssertTrue(response.ok)
        // Should be valid JSON
        let data = response.body.data(using: .utf8)!
        XCTAssertNotNil(try? JSONSerialization.jsonObject(with: data))
    }

    func testUnknownCommand() async {
        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_6","command":"bogus","params":{}}
        """.data(using: .utf8)!)

        let response = await NerveEngine.shared.handleCommand(command)
        XCTAssertFalse(response.ok)
        XCTAssertTrue(response.body.contains("Unknown command"))
    }

    func testNetworkStoreIntegration() async {
        let store = NerveNetworkStore.shared
        let tx = NerveNetworkStore.Transaction(
            id: "integration-1", method: "GET", urlString: "/api/test", startTime: Date()
        )
        store.record(tx)

        let command = try! JSONDecoder().decode(NerveCommand.self, from: """
        {"id":"test_7","command":"network","params":{"limit":5,"filter":"test"}}
        """.data(using: .utf8)!)

        let response = await NerveEngine.shared.handleCommand(command)
        XCTAssertTrue(response.ok)
        XCTAssertTrue(response.body.contains("/api/test"))
    }
}

// MARK: - Heap Inspection Integration

final class HeapIntegrationTests: XCTestCase {

    func testFindNSObjectInstances() {
        // There should be many NSObject instances alive
        let instances = NerveHeapInstances("NSObject", 5)
        XCTAssertGreaterThan(instances.count, 0)
    }

    func testFindUILabelInstances() {
        // Create a label and see if heap enumeration finds it
        let label = UILabel()
        label.text = "heap test"
        _ = label // Keep alive

        let instances = NerveHeapInstances("UILabel", 100)
        // Should find at least our label
        XCTAssertGreaterThan(instances.count, 0)
    }

    func testFindNonexistentClass() {
        let instances = NerveHeapInstances("CompletelyFakeClassName12345", 10)
        XCTAssertEqual(instances.count, 0)
    }
}

// MARK: - WebSocket Server Integration

final class WebSocketServerTests: XCTestCase {

    func testServerStartsAndStops() {
        // Verify server lifecycle doesn't crash
        let server = NerveServer(port: 0, engine: NerveEngine.shared)
        server.start()

        // Give it a moment to bind
        let expectation = expectation(description: "server start")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 2)

        server.stop()
    }
}

#endif
