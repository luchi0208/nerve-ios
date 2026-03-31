#if DEBUG

import Foundation
import NerveObjC

// MARK: - Command/Response Types

struct NerveCommand: Codable {
    let id: String
    let command: String
    let params: [String: AnyCodable]?

    func stringParam(_ key: String) -> String? {
        params?[key]?.value as? String
    }

    func intParam(_ key: String) -> Int? {
        if let i = params?[key]?.value as? Int { return i }
        if let d = params?[key]?.value as? Double { return Int(d) }
        return nil
    }

    func doubleParam(_ key: String) -> Double? {
        if let d = params?[key]?.value as? Double { return d }
        if let i = params?[key]?.value as? Int { return Double(i) }
        return nil
    }

    func boolParam(_ key: String) -> Bool? {
        params?[key]?.value as? Bool
    }
}

struct NerveResponse {
    let id: String
    let ok: Bool
    let body: String

    static func success(_ id: String, _ body: String) -> NerveResponse {
        NerveResponse(id: id, ok: true, body: body)
    }

    static func error(_ id: String, _ message: String) -> NerveResponse {
        NerveResponse(id: id, ok: false, body: message)
    }

    func toJSON() -> String {
        let escaped = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\t", with: "\\t")
        return """
        {"id":"\(id)","ok":\(ok),"data":"\(escaped)"}
        """
    }
}

/// Type-erased Codable wrapper for JSON params.
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) { self.value = value }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { value = NSNull() }
        else if let b = try? container.decode(Bool.self) { value = b }
        else if let i = try? container.decode(Int.self) { value = i }
        else if let d = try? container.decode(Double.self) { value = d }
        else if let s = try? container.decode(String.self) { value = s }
        else if let a = try? container.decode([AnyCodable].self) { value = a.map(\.value) }
        else if let d = try? container.decode([String: AnyCodable].self) { value = d.mapValues(\.value) }
        else { value = NSNull() }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let b as Bool: try container.encode(b)
        case let i as Int: try container.encode(i)
        case let d as Double: try container.encode(d)
        case let s as String: try container.encode(s)
        default: try container.encodeNil()
        }
    }
}

// MARK: - Accessibility Element Info

/// Represents a discovered accessibility element for `view` output.
struct NerveElement {
    let ref: String              // @e1, @e2, ...
    let type: String             // btn, txt, cell, toggle, field, scroll, img, etc.
    let label: String?           // accessibilityLabel
    let identifier: String?      // accessibilityIdentifier
    let value: String?           // accessibilityValue
    let frame: CGRect            // in screen coordinates
    let traits: UIAccessibilityTraits
    let isInteractable: Bool
    let depth: Int
    let presentationContext: String?  // "sheet", "modal", "root", nil
    let scrollContext: String?        // "vertical", "horizontal", nil
    let isDisabled: Bool
    let customActions: [String]       // names of custom accessibility actions

    // The raw NSObject for interaction (accessibilityActivate, etc.)
    weak var rawElement: NSObject?
    // The nearest UIView ancestor (for coordinate-based fallback)
    weak var containingView: UIView?
    // The activation point (may differ from frame center)
    let activationPoint: CGPoint
}

// MARK: - Formatting Helpers

func nerveFormatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes)B" }
    if bytes < 1024 * 1024 { return String(format: "%.1fKB", Double(bytes) / 1024) }
    return String(format: "%.1fMB", Double(bytes) / (1024 * 1024))
}

func nerveDescribeValue(_ value: Any) -> String {
    if let s = value as? String { return s.count > 80 ? "\(s.prefix(80))..." : s }
    if let n = value as? NSNumber { return n.stringValue }
    if let url = value as? URL { return url.absoluteString }
    if let color = value as? UIColor { return nerveDescribeColor(color) }
    if let image = value as? UIImage { return "UIImage(\(Int(image.size.width))x\(Int(image.size.height)))" }
    if let font = value as? UIFont { return "\(font.fontName) \(font.pointSize)pt" }
    return "\(value)"
}

func nerveDescribeColor(_ color: UIColor) -> String {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    color.getRed(&r, green: &g, blue: &b, alpha: &a)
    return String(format: "rgba(%.0f,%.0f,%.0f,%.1f)", r * 255, g * 255, b * 255, a)
}

func nerveDescribeTraits(_ traits: UIAccessibilityTraits) -> String {
    var names: [String] = []
    if traits.contains(.button) { names.append("button") }
    if traits.contains(.link) { names.append("link") }
    if traits.contains(.image) { names.append("image") }
    if traits.contains(.staticText) { names.append("text") }
    if traits.contains(.header) { names.append("header") }
    if traits.contains(.selected) { names.append("selected") }
    if traits.contains(.notEnabled) { names.append("disabled") }
    if traits.contains(.adjustable) { names.append("adjustable") }
    if traits.contains(.searchField) { names.append("search") }
    if traits.contains(.keyboardKey) { names.append("key") }
    if traits.contains(.tabBar) { names.append("tabBar") }
    if traits.contains(.updatesFrequently) { names.append("live") }
    return names.isEmpty ? "none" : names.joined(separator: ",")
}

func nerveAbbreviateType(element: NSObject, traits: UIAccessibilityTraits) -> String {
    if element is UIButton || traits.contains(.button) { return "btn" }
    if element is UITextField || traits.contains(.searchField) { return "field" }
    if element is UITextView { return "textview" }
    if element is UISwitch { return "toggle" }
    if element is UISlider || traits.contains(.adjustable) { return "slider" }
    if element is UIImageView || traits.contains(.image) { return "img" }
    if element is UILabel || traits.contains(.staticText) { return "txt" }
    if element is UIScrollView { return "scroll" }
    if element is UITableViewCell || element is UICollectionViewCell { return "cell" }
    if element is UINavigationBar { return "nav_bar" }
    if element is UITabBar || traits.contains(.tabBar) { return "tab_bar" }
    if traits.contains(.link) { return "link" }
    if traits.contains(.header) { return "header" }

    let className = NerveClassName(element)
    if className.contains("TabButton") || className.contains("TabItem") { return "tab" }
    if className.contains("Button") { return "btn" }
    if className.contains("TextField") || className.contains("SearchField") { return "field" }
    if className.contains("Switch") || className.contains("Toggle") { return "toggle" }

    return "view"
}

import UIKit

#endif
