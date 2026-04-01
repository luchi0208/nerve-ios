#if DEBUG

import Foundation
import Network
import UIKit
import os
import NerveObjC

// MARK: - Public API

public enum Nerve {
    public static func start(port: UInt16 = 0) {
        NerveEngine.shared.start(port: port)
    }

    public static func stop() {
        NerveEngine.shared.stop()
    }
}

@_cdecl("nerve_auto_start")
func nerveAutoStart() {
    Nerve.start()
}

// MARK: - Engine

final class NerveEngine {
    static let shared = NerveEngine()

    private var server: NerveServer?
    let console = NerveConsole()
    let navMap = NerveNavigationMap()
    private var started = false
    var lastActionTime: Date?

    func start(port: UInt16 = 0) {
        guard !started else { return }
        started = true

        NerveEnableAccessibility()
        // NerveInstallAutoTagging() // Disabled — merged into nav swizzle
        URLProtocol.registerClass(NerveURLProtocol.self)
        NerveStartNetworkInterception()
        console.start()
        navMap.loadFromDisk()
        installNavigationObserver()

        let resolvedPort: UInt16
        if port != 0 {
            resolvedPort = port
        } else if let udid = ProcessInfo.processInfo.environment["SIMULATOR_UDID"] {
            let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
            let key = "\(udid)-\(bundleId)"
            var hash: UInt32 = 5381
            for byte in key.utf8 {
                hash = ((hash &<< 5) &+ hash) &+ UInt32(byte)  // djb2
            }
            resolvedPort = 10000 + UInt16(hash % 55000)
        } else {
            resolvedPort = 9500
        }

        server = NerveServer(port: resolvedPort, engine: self)
        server?.start()
        os_log("[Nerve] Started on port %d", resolvedPort)
    }

    func stop() {
        server?.stop()
        console.stop()
        started = false
        os_log("[Nerve] Stopped")
    }

    // MARK: - Command Dispatch

    /// Commands that modify the UI and should auto-wait for settle
    private static let uiActionCommands: Set<String> = [
        "tap", "type", "scroll", "swipe", "back", "dismiss",
        "long_press", "double_tap", "drag_drop", "pull_to_refresh",
        "pinch", "context_menu", "action", "navigate", "deeplink"
    ]

    func handleCommand(_ command: NerveCommand) async -> NerveResponse {
        let response: NerveResponse

        switch command.command {
        case "view":       response = await handleView(command)
        case "tree":       response = await handleTree(command)
        case "inspect":    response = await handleInspect(command)
        case "tap":        response = await handleTap(command)
        case "long_press": response = await handleLongPress(command)
        case "double_tap": response = await handleDoubleTap(command)
        case "drag_drop":  response = await handleDragDrop(command)
        case "pull_to_refresh": response = await handlePullToRefresh(command)
        case "pinch":      response = await handlePinch(command)
        case "context_menu": response = await handleContextMenu(command)
        case "scroll":     response = await handleScroll(command)
        case "swipe":      response = await handleSwipe(command)
        case "type":       response = await handleType(command)
        case "back":       response = await handleBack(command)
        case "dismiss":    response = await handleDismiss(command)
        case "screenshot": response = await handleScreenshot(command)
        case "console":    response = handleConsole(command)
        case "network":    response = handleNetwork(command)
        case "heap":       response = handleHeap(command)
        case "storage":    response = await handleStorage(command)
        case "status":     response = handleStatus(command)
        case "map":        response = handleMap(command)
        case "navigate":   response = await handleNavigate(command)
        case "deeplink":   response = await handleDeeplink(command)
        case "grant_permissions": response = await handleGrantPermissions(command)
        case "wait_idle":  response = await handleWaitIdle(command)
        case "action":     response = await handleAction(command)
        case "scroll_to_find": response = await handleScrollToFind(command)
        case "trace":      response = handleTrace(command)
        case "highlight":  response = await handleHighlight(command)
        case "modify":     response = await handleModify(command)
        default:
            response = .error(command.id, "Unknown command: '\(command.command)'")
        }

        // Auto-wait for UI to settle after interaction commands, then auto-append view
        if response.ok && Self.uiActionCommands.contains(command.command) {
            await waitForUIToSettle()
            let viewResponse = await handleView(command)
            if viewResponse.ok {
                return .success(command.id, response.body + "\n" + viewResponse.body)
            }
        }

        return response
    }
}

#endif
