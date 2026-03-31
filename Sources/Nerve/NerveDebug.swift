#if DEBUG

import UIKit
import NerveObjC

// MARK: - Trace Callback (C-compatible function pointer)

private let traceCallback: NerveTraceCallback = { className, methodName, args in
    let cls = (className as String?) ?? "?"
    let method = (methodName as String?) ?? "?"
    let argsStr = (args as String?) ?? ""
    let msg = "[trace] [\(cls) \(method)] \(argsStr)"
    NerveEngine.shared.console.addLog(msg, level: .info)
}

// MARK: - Debug Commands (trace, highlight, modify)

extension NerveEngine {

    // MARK: - Trace

    func handleTrace(_ command: NerveCommand) -> NerveResponse {
        let action = command.stringParam("action") ?? "add"

        switch action {
        case "add":
            guard let className = command.stringParam("class_name") else {
                return .error(command.id, "Missing 'class_name' parameter")
            }
            guard let methodName = command.stringParam("method") else {
                return .error(command.id, "Missing 'method' parameter")
            }
            let isClassMethod = command.stringParam("type") == "class"

            let success = NerveInstallTrace(className, methodName, isClassMethod, traceCallback)

            if success {
                let prefix = isClassMethod ? "+" : "-"
                return .success(command.id, "Tracing \(prefix)[\(className) \(methodName)] — view calls with nerve console")
            } else {
                return .error(command.id, "Failed to install trace. Check class '\(className)' and method '\(methodName)' exist.")
            }

        case "remove":
            guard let className = command.stringParam("class_name") else {
                return .error(command.id, "Missing 'class_name' parameter")
            }
            guard let methodName = command.stringParam("method") else {
                return .error(command.id, "Missing 'method' parameter")
            }
            let isClassMethod = command.stringParam("type") == "class"
            let removed = NerveRemoveTrace(className, methodName, isClassMethod)
            return removed
                ? .success(command.id, "Removed trace on \(className).\(methodName)")
                : .error(command.id, "No active trace on \(className).\(methodName)")

        case "remove_all":
            NerveRemoveAllTraces()
            return .success(command.id, "Removed all traces")

        case "list":
            let count = NerveActiveTraceCount()
            return .success(command.id, "Active traces: \(count)")

        default:
            return .error(command.id, "Unknown action '\(action)'. Use: add, remove, remove_all, list")
        }
    }

    // MARK: - Highlight

    @MainActor
    func handleHighlight(_ command: NerveCommand) async -> NerveResponse {
        let action = command.stringParam("action") ?? "show"

        if action == "clear" {
            clearHighlights()
            return .success(command.id, "Cleared all highlights")
        }

        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }

        let colorName = command.stringParam("color") ?? "red"
        let color = parseColor(colorName)

        guard let element = NerveElementResolver.resolve(query: query),
              let view = element.containingView else {
            return .error(command.id, "Element not found: '\(query)'")
        }

        // Add a highlight border
        highlightCounter += 1

        let overlay = UIView(frame: view.bounds)
        overlay.layer.borderColor = color.cgColor
        overlay.layer.borderWidth = 3
        overlay.layer.backgroundColor = color.withAlphaComponent(0.1).cgColor
        overlay.isUserInteractionEnabled = false
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(overlay)
        activeHighlights.append(overlay)

        return .success(command.id, "Highlighted '\(query)' with \(colorName) border")
    }

    private func clearHighlights() {
        for overlay in activeHighlights {
            overlay.removeFromSuperview()
        }
        activeHighlights.removeAll()
    }

    private func parseColor(_ name: String) -> UIColor {
        switch name.lowercased() {
        case "red": return .systemRed
        case "blue": return .systemBlue
        case "green": return .systemGreen
        case "yellow": return .systemYellow
        case "orange": return .systemOrange
        case "purple": return .systemPurple
        case "pink": return .systemPink
        case "cyan": return .systemCyan
        default: return .systemRed
        }
    }

    // MARK: - Modify

    @MainActor
    func handleModify(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }

        guard let element = NerveElementResolver.resolve(query: query),
              let view = element.containingView else {
            return .error(command.id, "Element not found: '\(query)'")
        }

        var changes: [String] = []

        if let hidden = command.stringParam("hidden") {
            view.isHidden = (hidden == "true" || hidden == "1")
            changes.append("hidden=\(view.isHidden)")
        }

        if let alpha = command.stringParam("alpha") {
            if let val = Double(alpha) {
                view.alpha = CGFloat(val)
                changes.append("alpha=\(val)")
            }
        }

        if let bgColor = command.stringParam("backgroundColor") {
            view.backgroundColor = parseColor(bgColor)
            changes.append("backgroundColor=\(bgColor)")
        }

        if let text = command.stringParam("text") {
            if let label = view as? UILabel {
                label.text = text
                changes.append("text=\"\(text)\"")
            } else if let textField = view as? UITextField {
                textField.text = text
                changes.append("text=\"\(text)\"")
            } else if let textView = view as? UITextView {
                textView.text = text
                changes.append("text=\"\(text)\"")
            } else if let button = view as? UIButton {
                button.setTitle(text, for: .normal)
                changes.append("title=\"\(text)\"")
            } else if view.responds(to: NSSelectorFromString("setText:")) {
                view.setValue(text, forKey: "text")
                changes.append("text=\"\(text)\"")
            } else {
                return .error(command.id, "View doesn't support text modification")
            }
        }

        if let enabled = command.stringParam("enabled") {
            if let control = view as? UIControl {
                control.isEnabled = (enabled == "true" || enabled == "1")
                changes.append("enabled=\(control.isEnabled)")
            }
        }

        // KVC for arbitrary properties
        if let key = command.stringParam("key"), let value = command.stringParam("value") {
            if let num = Double(value) {
                view.setValue(NSNumber(value: num), forKey: key)
            } else if value == "true" || value == "false" {
                view.setValue(NSNumber(value: value == "true"), forKey: key)
            } else {
                view.setValue(value, forKey: key)
            }
            changes.append("\(key)=\(value)")
        }

        if changes.isEmpty {
            return .error(command.id, "No modifications specified. Use: hidden, alpha, backgroundColor, text, enabled, or key+value")
        }

        return .success(command.id, "Modified '\(query)': \(changes.joined(separator: ", "))")
    }
}

// Storage for highlights
extension NerveEngine {
    private static var _highlights: [UIView] = []
    private static var _highlightCounter: Int = 0

    var activeHighlights: [UIView] {
        get { NerveEngine._highlights }
        set { NerveEngine._highlights = newValue }
    }

    var highlightCounter: Int {
        get { NerveEngine._highlightCounter }
        set { NerveEngine._highlightCounter = newValue }
    }
}

#endif
