#if DEBUG

import Foundation
import UIKit
import NerveObjC

// MARK: - Navigation Map

struct NerveScreen: Codable, Hashable {
    let name: String
    func hash(into hasher: inout Hasher) { hasher.combine(name) }
    static func == (lhs: NerveScreen, rhs: NerveScreen) -> Bool { lhs.name == rhs.name }
}

struct NerveNavEdge: Codable {
    let from: String
    let to: String
    let action: String
    var element: String?
    var elementId: String?
    var requiresInput: Bool
    var inputFields: [String]
    var visitCount: Int
}

final class NerveNavigationMap {
    private let lock = NSLock()
    private(set) var edges: [String: [NerveNavEdge]] = [:]
    private(set) var screens: Set<String> = []
    private(set) var currentScreen: String?
    var lastTappedElement: (label: String?, identifier: String?)?

    /// File path for persisting the nav map across sessions
    private lazy var persistPath: String = {
        let bundleId = Bundle.main.bundleIdentifier ?? "unknown"
        let dir = "/tmp/nerve-nav"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return "\(dir)/\(bundleId).json"
    }()

    /// Load persisted nav map from disk
    func loadFromDisk() {
        guard FileManager.default.fileExists(atPath: persistPath),
              let json = try? String(contentsOfFile: persistPath, encoding: .utf8) else { return }
        loadJSON(json)
    }

    /// Save nav map to disk
    private func saveToDisk() {
        let json = toJSON()
        try? json.write(toFile: persistPath, atomically: true, encoding: .utf8)
    }

    func recordTransition(from: String, to: String, action: String) {
        lock.withLock {
            screens.insert(to)
            if !from.isEmpty { screens.insert(from) }

            let effectiveFrom = from.isEmpty ? (currentScreen ?? "(unknown)") : from
            var edgeList = edges[effectiveFrom] ?? []
            if let idx = edgeList.firstIndex(where: { $0.to == to && $0.action == action }) {
                edgeList[idx].visitCount += 1
                if let tapped = lastTappedElement {
                    edgeList[idx].element = tapped.label ?? edgeList[idx].element
                    edgeList[idx].elementId = tapped.identifier ?? edgeList[idx].elementId
                }
            } else {
                let edge = NerveNavEdge(
                    from: effectiveFrom, to: to, action: action,
                    element: lastTappedElement?.label, elementId: lastTappedElement?.identifier,
                    requiresInput: false, inputFields: [], visitCount: 1
                )
                edgeList.append(edge)
            }
            edges[effectiveFrom] = edgeList
            lastTappedElement = nil
            if action == "appear" { currentScreen = to }
        }
        saveToDisk()
    }

    func markScreenRequiresInput(_ screen: String, fields: [String]) {
        lock.withLock {
            for (key, edgeList) in edges {
                for i in edgeList.indices where edgeList[i].to == screen {
                    edges[key]![i].requiresInput = true
                    edges[key]![i].inputFields = fields
                }
            }
        }
    }

    func findPath(to target: String) -> [NerveNavEdge]? {
        lock.withLock {
            guard let start = currentScreen else { return nil }
            if start == target { return [] }
            var queue: [(screen: String, path: [NerveNavEdge])] = [(start, [])]
            var visited: Set<String> = [start]
            while !queue.isEmpty {
                let (current, path) = queue.removeFirst()
                for edge in edges[current] ?? [] {
                    if visited.contains(edge.to) { continue }
                    let newPath = path + [edge]
                    if edge.to == target { return newPath }
                    visited.insert(edge.to)
                    queue.append((edge.to, newPath))
                }
            }
            return nil
        }
    }

    func describe() -> String {
        lock.withLock {
            if screens.isEmpty { return "Navigation map is empty. Navigate the app to build the map." }
            var lines: [String] = []
            lines.append("screens: \(screens.count) | edges: \(edges.values.flatMap { $0 }.count) | current: \(currentScreen ?? "unknown")")
            lines.append("---")
            for screen in screens.sorted() {
                let outgoing = edges[screen] ?? []
                let marker = screen == currentScreen ? " ←" : ""
                lines.append("\(screen)\(marker)")
                for edge in outgoing {
                    var desc = "  → \(edge.to) via \(edge.action)"
                    if let el = edge.elementId ?? edge.element { desc += " (\(el))" }
                    if edge.requiresInput { desc += " [requires input]" }
                    desc += " ×\(edge.visitCount)"
                    lines.append(desc)
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    func toJSON() -> String {
        lock.withLock {
            let allEdges = edges.values.flatMap { $0 }
            let data = try? JSONEncoder().encode(allEdges)
            return data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        }
    }

    func loadJSON(_ json: String) {
        lock.withLock {
            guard let data = json.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([NerveNavEdge].self, from: data) else { return }
            for edge in decoded {
                screens.insert(edge.from)
                screens.insert(edge.to)
                var edgeList = edges[edge.from] ?? []
                edgeList.append(edge)
                edges[edge.from] = edgeList
            }
        }
    }
}

// MARK: - Navigation Commands

extension NerveEngine {

    func installNavigationObserver() {
        let callback: NerveNavCallback = { from, to, action in
            let toStr = String(to)
            let actionStr = String(action)
            // Skip internal framework VCs that don't represent real screens
            let skipPrefixes = ["UI", "_UI", "NS", "_NS", "SwiftUI."]
            if skipPrefixes.contains(where: { toStr.hasPrefix($0) }) && actionStr == "appear" { return }
            // Skip unknown/empty screen names
            if toStr == "(unknown)" || toStr.isEmpty { return }
            NerveEngine.shared.navMap.recordTransition(from: String(from), to: toStr, action: actionStr)
        }
        NerveInstallNavigationSwizzles(callback)
    }

    func recordTapForNavigation(label: String?, identifier: String?) {
        navMap.lastTappedElement = (label: label, identifier: identifier)
    }

    func handleMap(_ command: NerveCommand) -> NerveResponse {
        let format = command.stringParam("format") ?? "text"
        if format == "json" { return .success(command.id, navMap.toJSON()) }
        if let importJSON = command.stringParam("import") {
            navMap.loadJSON(importJSON)
            return .success(command.id, "Imported navigation map. \(navMap.describe())")
        }
        return .success(command.id, navMap.describe())
    }

    @MainActor
    func handleNavigate(_ command: NerveCommand) async -> NerveResponse {
        guard let target = command.stringParam("target") else {
            return .error(command.id, "Missing 'target' parameter")
        }

        let inputs: [String: String]
        if let dict = command.params?["inputs"]?.value as? [String: Any] {
            inputs = dict.compactMapValues { $0 as? String }
        } else {
            inputs = [:]
        }

        if navMap.currentScreen == target {
            return .success(command.id, "Already at \(target)")
        }

        // Find path (exact or fuzzy)
        var path = navMap.findPath(to: target)
        if path == nil {
            let matches = navMap.screens.filter { $0.localizedCaseInsensitiveContains(target) }
            if matches.count == 1, let match = matches.first {
                path = navMap.findPath(to: match)
            }
            if path == nil {
                let known = navMap.screens.isEmpty ? "(none)" : navMap.screens.sorted().joined(separator: ", ")
                return .error(command.id, "No path found to '\(target)'. Known screens: \(known)")
            }
        }

        return await executeNavigation(command: command, path: path!, target: target, inputs: inputs)
    }

    @MainActor
    private func executeNavigation(command: NerveCommand, path: [NerveNavEdge], target: String, inputs: [String: String]) async -> NerveResponse {
        var log: [String] = ["Navigating to \(target) (\(path.count) steps)"]

        for (i, edge) in path.enumerated() {
            log.append("Step \(i + 1)/\(path.count): \(edge.action) → \(edge.to)")
            NerveElementResolver.invalidateCache()

            switch edge.action {
            case "push", "tap", "present":
                if let elementId = edge.elementId, let el = NerveElementResolver.resolve(query: elementId) {
                    if let raw = el.rawElement { raw.accessibilityActivate() }
                    log.append("  Activated #\(elementId)")
                } else if let label = edge.element, let el = NerveElementResolver.resolve(query: "@\(label)") {
                    if let raw = el.rawElement { raw.accessibilityActivate() }
                    log.append("  Activated '\(label)'")
                } else {
                    log.append("  FAILED: element not found")
                    return .error(command.id, log.joined(separator: "\n"))
                }

            case "tab":
                // Find UITabBarController and switch
                let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
                if let tabController = findTabBarController(in: windows) {
                    // Match by tab title
                    if let vcs = tabController.viewControllers {
                        for (idx, vc) in vcs.enumerated() {
                            let vcName = NerveClassName(vc)
                            if edge.to.contains(vcName) || vcName.contains(edge.to) {
                                tabController.selectedIndex = idx
                                log.append("  Selected tab \(idx)")
                                break
                            }
                        }
                    }
                } else if let label = edge.element, let el = NerveElementResolver.resolve(query: "@\(label)") {
                    if let raw = el.rawElement { raw.accessibilityActivate() }
                    log.append("  Tapped tab '\(label)'")
                }

            default:
                log.append("  (unknown action: \(edge.action))")
            }

            try? await Task.sleep(nanoseconds: 500_000_000)

            // Fill input fields if needed
            if edge.requiresInput && !inputs.isEmpty {
                for fieldId in edge.inputFields {
                    if let value = inputs[fieldId] ?? inputs["#\(fieldId)"],
                       let el = NerveElementResolver.resolve(query: fieldId) {
                        if let raw = el.rawElement { raw.accessibilityActivate() }
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        if let tf = el.containingView as? UITextField {
                            tf.text = value
                            tf.sendActions(for: .editingChanged)
                        }
                        log.append("  Filled #\(fieldId)")
                    }
                }
            }
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
        let current = navMap.currentScreen ?? "unknown"
        log.append(current == target ? "Arrived at \(target)" : "Expected \(target), at \(current)")
        return .success(command.id, log.joined(separator: "\n"))
    }

    private func findTabBarController(in windows: [UIWindow]) -> UITabBarController? {
        for window in windows {
            if let tbc = findTabBarControllerFrom(window.rootViewController) { return tbc }
        }
        return nil
    }

    private func findTabBarControllerFrom(_ vc: UIViewController?) -> UITabBarController? {
        guard let vc else { return nil }
        if let tbc = vc as? UITabBarController { return tbc }
        if let presented = vc.presentedViewController {
            if let tbc = findTabBarControllerFrom(presented) { return tbc }
        }
        for child in vc.children {
            if let tbc = findTabBarControllerFrom(child) { return tbc }
        }
        return nil
    }

    // MARK: - Deeplink

    @MainActor
    func handleDeeplink(_ command: NerveCommand) async -> NerveResponse {
        guard let urlString = command.stringParam("url") else {
            return .error(command.id, "Missing 'url' parameter")
        }
        guard let url = URL(string: urlString) else {
            return .error(command.id, "Invalid URL: '\(urlString)'")
        }

        let opened = await UIApplication.shared.open(url)
        if opened {
            NerveElementResolver.invalidateCache()
            NervePostAccessibilityNotifications()
            return .success(command.id, "Opened deeplink: \(urlString)")
        } else {
            return .error(command.id, "App could not open URL: \(urlString). Make sure the URL scheme is registered.")
        }
    }

    // MARK: - Grant Permissions

    @MainActor
    func handleGrantPermissions(_ command: NerveCommand) async -> NerveResponse {
        // This runs in-process — we can only grant via simctl from the Mac side.
        // Return instructions for the MCP server to handle it.
        return .error(command.id, "grant_permissions must be called from the MCP server (Mac-side). Use nerve_grant_permissions tool.")
    }
}

#endif
