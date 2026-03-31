#if DEBUG

import UIKit
import NerveObjC

// MARK: - Inspection Commands

extension NerveEngine {

    // MARK: - view

    @MainActor
    func handleView(_ command: NerveCommand) async -> NerveResponse {
        let elements = NerveElementResolver.collectElements()
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        let keyWindow = windows.first
        let screenSize = keyWindow?.screen.bounds.size ?? UIScreen.main.bounds.size

        let navTitle = findNavigationTitle(in: windows)
        let modalState = findModalState(in: windows)

        var lines: [String] = []
        lines.append("screen \(Int(screenSize.width))x\(Int(screenSize.height)) | nav=\"\(navTitle ?? "none")\" | modal=\(modalState)")
        lines.append("---")

        for el in elements {
            var parts: [String] = ["\(el.ref) \(el.type)"]

            if let label = el.label { parts.append("\"\(label)\"") }
            if let id = el.identifier { parts.append("#\(id)") }
            if let value = el.value { parts.append("val=\(value)") }

            let ap = el.activationPoint
            parts.append("tap=\(Int(ap.x)),\(Int(ap.y))")

            let f = el.frame
            if f.origin.x > 10 || f.size.width < screenSize.width - 20 {
                parts.append("x=\(Int(f.origin.x))")
            }
            parts.append("y=\(Int(f.origin.y))")
            if f.size.width < screenSize.width - 20 {
                parts.append("w=\(Int(f.size.width))")
            }
            parts.append("h=\(Int(f.size.height))")

            if el.traits.contains(.selected) { parts.append("selected") }
            if el.isDisabled { parts.append("disabled") }
            if let ctx = el.presentationContext { parts.append("[\(ctx)]") }

            lines.append(parts.joined(separator: " "))
        }

        return .success(command.id, lines.joined(separator: "\n"))
    }

    // MARK: - tree

    @MainActor
    func handleTree(_ command: NerveCommand) async -> NerveResponse {
        let maxDepth = command.intParam("depth") ?? 50
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()

        var lines: [String] = []
        for window in windows {
            walkViewTree(view: window, depth: 0, maxDepth: maxDepth, lines: &lines)
        }

        return .success(command.id, lines.joined(separator: "\n"))
    }

    // MARK: - inspect

    @MainActor
    func handleInspect(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }

        guard let element = NerveElementResolver.resolve(query: query) else {
            return .error(command.id, "Element not found: '\(query)'")
        }

        var lines: [String] = []
        let typeName = element.rawElement.map { NerveClassName($0) } ?? element.type
        lines.append("view: \(typeName) \(element.identifier.map { "#\($0)" } ?? "")")
        lines.append("  class: \(typeName)")
        lines.append("  frame: \(Int(element.frame.origin.x)),\(Int(element.frame.origin.y)) \(Int(element.frame.width))x\(Int(element.frame.height))")

        let traits = nerveDescribeTraits(element.traits)
        lines.append("  accessibility: label=\"\(element.label ?? "nil")\" id=\"\(element.identifier ?? "nil")\" traits=[\(traits)]")
        lines.append("  interactable: \(element.isInteractable) disabled: \(element.isDisabled)")

        if let ctx = element.presentationContext { lines.append("  context: \(ctx)") }
        if let scroll = element.scrollContext { lines.append("  scroll: \(scroll)") }

        if let view = element.containingView {
            lines.append("  state: hidden=\(view.isHidden) alpha=\(String(format: "%.1f", view.alpha))")
            if let vc = NerveViewControllerForView(view) {
                lines.append("  vc: \(NerveClassName(vc))")
            }

            // Common properties via KVC
            lines.append("  props:")
            for key in commonProperties(for: view) {
                if let val = NerveReadProperty(view, key) {
                    lines.append("    \(key) = \(nerveDescribeValue(val))")
                }
            }
        }

        // Custom accessibility actions
        if !element.customActions.isEmpty {
            lines.append("  actions: \(element.customActions.joined(separator: ", "))")
        }

        // Swift Mirror for stored properties
        if let raw = element.rawElement {
            let mirror = Mirror(reflecting: raw)
            var mirrorLines: [String] = []
            for child in mirror.children.prefix(10) {
                if let label = child.label, !label.hasPrefix("_") {
                    mirrorLines.append("    \(label) = \(nerveDescribeValue(child.value))")
                }
            }
            if !mirrorLines.isEmpty {
                lines.append(contentsOf: mirrorLines)
            }
        }

        return .success(command.id, lines.joined(separator: "\n"))
    }

    // MARK: - Screenshot

    @MainActor
    func handleScreenshot(_ command: NerveCommand) async -> NerveResponse {
        let scale = command.doubleParam("scale") ?? 1.0
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        guard let window = windows.first else {
            return .error(command.id, "No window available")
        }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { ctx in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
        }

        let finalImage: UIImage
        if scale < 1.0 {
            let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let resizeRenderer = UIGraphicsImageRenderer(size: newSize)
            finalImage = resizeRenderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
        } else {
            finalImage = image
        }

        guard let data = finalImage.pngData() else {
            return .error(command.id, "Failed to capture screenshot")
        }

        return .success(command.id, "data:image/png;base64,\(data.base64EncodedString())")
    }

    // MARK: - Helpers

    private func walkViewTree(view: UIView, depth: Int, maxDepth: Int, lines: inout [String]) {
        guard depth <= maxDepth else { return }
        let indent = String(repeating: "  ", count: depth)
        let className = NerveClassName(view)
        let f = view.frame
        var line = "\(indent)\(className) \(Int(f.origin.x)),\(Int(f.origin.y)) \(Int(f.width))x\(Int(f.height))"

        if let label = view.accessibilityLabel { line += " \"\(label)\"" }
        if let id = view.accessibilityIdentifier { line += " #\(id)" }
        if view.isHidden { line += " [hidden]" }
        if view.alpha < 0.01 { line += " [invisible]" }

        lines.append(line)
        for subview in view.subviews {
            walkViewTree(view: subview, depth: depth + 1, maxDepth: maxDepth, lines: &lines)
        }
    }

    @MainActor
    private func findNavigationTitle(in windows: [UIWindow]) -> String? {
        guard let window = windows.first, let topVC = topViewController(in: window) else { return nil }
        return topVC.navigationItem.title ?? topVC.title
    }

    @MainActor
    private func findModalState(in windows: [UIWindow]) -> String {
        guard let window = windows.first, let rootVC = window.rootViewController else { return "none" }
        var vc = rootVC
        while let presented = vc.presentedViewController { vc = presented }
        if vc === rootVC { return "none" }
        let name = NerveClassName(vc)
        if name.contains("Alert") { return "alert" }
        if vc.modalPresentationStyle == .pageSheet || vc.modalPresentationStyle == .formSheet { return "sheet" }
        return "modal"
    }

    private func commonProperties(for view: UIView) -> [String] {
        var keys: [String] = []
        if view is UILabel { keys += ["text", "font", "textColor", "numberOfLines"] }
        if view is UIButton { keys += ["currentTitle", "isEnabled", "isHighlighted"] }
        if view is UITextField { keys += ["text", "placeholder", "isEditing"] }
        if view is UITextView { keys += ["text", "isEditable"] }
        if view is UIImageView { keys += ["image", "contentMode"] }
        if view is UISwitch { keys += ["isOn"] }
        if view is UISlider { keys += ["value", "minimumValue", "maximumValue"] }
        return keys
    }
}

#endif
