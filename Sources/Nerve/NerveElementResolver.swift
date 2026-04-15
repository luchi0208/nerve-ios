#if DEBUG

import UIKit
import NerveObjC

// MARK: - Element Resolver

/// Finds accessibility elements by identifier, label, type, or coordinates.
/// Searches the accessibility tree (not the UIView tree) so SwiftUI elements are found.
/// Handles modals, sheets, scroll views, and disabled elements.
final class NerveElementResolver {

    /// Maximum elements to collect during a tree walk.
    static let maxElements = 500

    /// Maximum recursion depth for tree walking.
    static let maxDepth = 20

    /// Cache TTL — avoid redundant walks within 300ms.
    private static var cachedElements: [NerveElement] = []
    private static var cacheTime: Date = .distantPast

    // MARK: - Public API

    /// Collect all accessibility elements from all windows.
    @MainActor
    static func collectElements() -> [NerveElement] {
        // Return cache if fresh
        if Date().timeIntervalSince(cacheTime) < 0.3 && !cachedElements.isEmpty {
            return cachedElements
        }

        let windows = NerveGetAllWindows() as? [UIWindow] ?? allWindowsPublic()
        var elements: [NerveElement] = []
        var refCounter = 1

        // Find the topmost modal window/VC for presentation context
        let modalVC = findTopmostPresentedVC(in: windows)

        for window in windows {
            walkAccessibilityTree(
                root: window,
                depth: 0,
                refCounter: &refCounter,
                elements: &elements,
                modalVC: modalVC,
                screenBounds: window.screen.bounds
            )
            if elements.count >= maxElements { break }
        }

        // If accessibility tree is sparse, post VoiceOver notifications and retry
        if elements.filter({ $0.isInteractable }).count < 2 {
            NervePostAccessibilityNotifications()
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
            elements.removeAll()
            refCounter = 1
            for window in windows {
                walkAccessibilityTree(
                    root: window, depth: 0, refCounter: &refCounter,
                    elements: &elements, modalVC: modalVC,
                    screenBounds: window.screen.bounds
                )
                if elements.count >= maxElements { break }
            }
        }

        // Build frame key set from accessibility results for dedup
        var existingFrames = Set(elements.map { frameKey($0.frame) })

        // UIView hierarchy walk — find interactive views missed by accessibility tree
        for window in windows {
            walkViewHierarchy(
                root: window, depth: 0, refCounter: &refCounter,
                elements: &elements, existingFrames: &existingFrames,
                modalVC: modalVC, screenBounds: window.screen.bounds
            )
            if elements.count >= maxElements { break }
        }

        // CALayer discovery — find SwiftUI controls without UIView backing
        for window in windows {
            walkLayerTree(
                root: window, refCounter: &refCounter,
                elements: &elements, existingFrames: &existingFrames,
                screenBounds: window.screen.bounds
            )
            if elements.count >= maxElements { break }
        }

        // Ghost node filtering — remove stale elements from SwiftUI List deletions.
        // When 2+ elements share the same frame origin but have different labels,
        // the last one in walk order is current; earlier ones are ghosts.
        elements = filterGhostNodes(elements)

        cachedElements = elements
        cacheTime = Date()
        return elements
    }

    /// Invalidate the element cache (call after interactions).
    static func invalidateCache() {
        cachedElements = []
        cacheTime = .distantPast
    }

    /// Find an element matching a query string.
    @MainActor
    static func resolve(query: String) -> NerveElement? {
        // Coordinate query: "x,y"
        if let point = parseCoordinates(query) {
            return resolveByPoint(point)
        }

        let elements = collectElements()

        // Identifier query: "#identifier"
        if query.hasPrefix("#") {
            let id = String(query.dropFirst())
            return resolveByIdentifier(id, in: elements)
        }

        // Element ref query: "@e1", "@e2", etc. (from nerve_view output)
        if query.hasPrefix("@e"), let index = Int(query.dropFirst(2)), index >= 1, index <= elements.count {
            return elements[index - 1]
        }

        // Label query: "@label"
        if query.hasPrefix("@") {
            let label = String(query.dropFirst())
            return resolveByLabel(label, in: elements)
        }

        // Type query: ".ClassName:index"
        if query.hasPrefix(".") {
            let spec = String(query.dropFirst())
            return resolveByType(spec, in: elements)
        }

        // Bare string — try identifier first, then label
        if let found = resolveByIdentifier(query, in: elements) { return found }
        return resolveByLabel(query, in: elements)
    }

    // MARK: - Resolution Strategies

    private static func resolveByIdentifier(_ id: String, in elements: [NerveElement]) -> NerveElement? {
        let matches = elements.filter { $0.identifier == id }
        return pickBest(matches)
    }

    private static func resolveByLabel(_ label: String, in elements: [NerveElement]) -> NerveElement? {
        // Exact match first
        let exact = elements.filter { $0.label == label }
        if let found = pickBest(exact) { return found }

        // Contains match
        let partial = elements.filter { $0.label?.localizedCaseInsensitiveContains(label) == true }
        return pickBest(partial)
    }

    private static func resolveByType(_ spec: String, in elements: [NerveElement]) -> NerveElement? {
        let parts = spec.split(separator: ":")
        let typeName = String(parts[0])
        let index = parts.count > 1 ? Int(parts[1]) : 0

        let matches = elements.filter { el in
            el.type == typeName || (el.rawElement.map { NerveClassName($0).contains(typeName) } ?? false)
        }

        if let idx = index, idx < matches.count { return matches[idx] }
        return matches.first
    }

    @MainActor
    private static func resolveByPoint(_ point: CGPoint) -> NerveElement? {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? allWindowsPublic()
        // Search windows in reverse (topmost first)
        for window in windows.reversed() {
            if let hit = window.hitTest(point, with: nil), hit !== window {
                return NerveElement(
                    ref: "@hit", type: nerveAbbreviateType(element: hit, traits: hit.accessibilityTraits),
                    label: hit.accessibilityLabel, identifier: hit.accessibilityIdentifier,
                    value: hit.accessibilityValue, frame: hit.convert(hit.bounds, to: nil),
                    traits: hit.accessibilityTraits, isInteractable: true, depth: 0,
                    presentationContext: nil, scrollContext: nil,
                    isDisabled: hit.accessibilityTraits.contains(.notEnabled),
                    customActions: [],
                    rawElement: hit, containingView: hit,
                    activationPoint: point
                )
            }
        }
        return nil
    }

    // MARK: - Best Candidate Selection

    /// Pick the best element when multiple match — prefers modal/sheet elements,
    /// then interactable, then visible on-screen.
    private static func pickBest(_ candidates: [NerveElement]) -> NerveElement? {
        if candidates.isEmpty { return nil }
        if candidates.count == 1 { return candidates[0] }

        // Tier 1: Elements in sheet/modal (topmost presented content)
        let modal = candidates.filter { $0.presentationContext == "sheet" || $0.presentationContext == "modal" }
        if let best = modal.first { return best }

        // Tier 2: Interactable + visible on screen
        let interactableOnScreen = candidates.filter { $0.isInteractable && isOnScreen($0) }
        if let best = interactableOnScreen.first { return best }

        // Tier 3: Visible on screen
        let onScreen = candidates.filter { isOnScreen($0) }
        if let best = onScreen.first { return best }

        // Tier 4: First match
        return candidates.first
    }

    private static func isOnScreen(_ element: NerveElement) -> Bool {
        let screen = UIScreen.main.bounds
        return screen.intersects(element.frame) && element.frame != .zero
    }

    // MARK: - 5-Point Hit Test (#6)

    /// Verify an element is actually tappable by testing 5 points (center + 4 inset corners).
    /// Returns true if at least one point hits the element or a descendant.
    @MainActor
    static func isTappable(_ element: NerveElement) -> Bool {
        guard let containingView = element.containingView, let window = containingView.window else {
            // For non-UIView elements, check if activation point is on-screen
            return element.activationPoint != .zero && UIScreen.main.bounds.contains(element.activationPoint)
        }

        let frame = element.frame
        if frame == .zero { return false }

        // Inset by 15% on each side
        let insetX = frame.width * 0.15
        let insetY = frame.height * 0.15
        let insetFrame = frame.insetBy(dx: insetX, dy: insetY)

        let testPoints = [
            CGPoint(x: insetFrame.midX, y: insetFrame.midY),      // center
            CGPoint(x: insetFrame.minX, y: insetFrame.minY),      // top-left
            CGPoint(x: insetFrame.maxX, y: insetFrame.minY),      // top-right
            CGPoint(x: insetFrame.minX, y: insetFrame.maxY),      // bottom-left
            CGPoint(x: insetFrame.maxX, y: insetFrame.maxY),      // bottom-right
        ]

        for point in testPoints {
            // Convert screen coords to window coords
            let windowPoint = window.convert(point, from: nil)
            if let hitView = window.hitTest(windowPoint, with: nil) {
                // Check if hit view is the target, an ancestor, or a descendant
                if hitView === containingView
                    || hitView.isDescendant(of: containingView)
                    || containingView.isDescendant(of: hitView) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Scroll-to-Find (#9)

    /// Try to find an element by scrolling through scroll views.
    /// For lazy containers (LazyVStack/LazyHStack), elements only exist when scrolled into view.
    @MainActor
    static func scrollToFind(query: String, maxAttempts: Int = 10) -> NerveElement? {
        // First try without scrolling
        if let found = resolve(query: query) { return found }

        let windows = NerveGetAllWindows() as? [UIWindow] ?? allWindowsPublic()
        guard let window = windows.first else { return nil }

        // Find all scroll views
        var scrollViews: [UIScrollView] = []
        findAllScrollViews(in: window, results: &scrollViews)

        for scrollView in scrollViews {
            let pageHeight = scrollView.bounds.height * 0.8
            let maxScroll = scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom

            for attempt in 0..<maxAttempts {
                let newY = min(scrollView.contentOffset.y + pageHeight, maxScroll)
                if newY <= scrollView.contentOffset.y { break } // Can't scroll further

                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: newY), animated: false)

                // Pump the run loop to let lazy containers render
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))

                // Invalidate cache and try again
                invalidateCache()
                if let found = resolve(query: query) { return found } // Found — leave scroll position as-is
            }

            // Not found in this scroll view — reset scroll position
            scrollView.setContentOffset(.zero, animated: false)
        }

        return nil
    }

    private static func findAllScrollViews(in view: UIView, results: inout [UIScrollView]) {
        if let sv = view as? UIScrollView, !(sv is UITextView),
           sv.contentSize.height > sv.bounds.height || sv.contentSize.width > sv.bounds.width {
            results.append(sv)
        }
        for subview in view.subviews {
            findAllScrollViews(in: subview, results: &results)
        }
    }

    // MARK: - Accessibility Tree Walk

    @MainActor
    private static func walkAccessibilityTree(
        root: NSObject, depth: Int, refCounter: inout Int,
        elements: inout [NerveElement],
        modalVC: UIViewController?,
        screenBounds: CGRect
    ) {
        guard depth <= maxDepth else { return }
        guard elements.count < maxElements else { return }

        // Skip hidden views
        if let view = root as? UIView {
            if view.isHidden || view.alpha < 0.01 { return }
        }

        // Skip elements hidden from accessibility
        if root.accessibilityElementsHidden { return }

        // If this element IS an accessibility element (leaf), record it
        if root.isAccessibilityElement {
            if let element = buildElement(from: root, depth: depth, refCounter: &refCounter,
                                           modalVC: modalVC, screenBounds: screenBounds) {
                elements.append(element)
            }
            return
        }

        // Check for modal — if a subview has accessibilityViewIsModal, walk that subtree.
        // At depth 0 (window level), also walk siblings after the modal to catch nested
        // presentations (e.g. sheet on top of fullScreenCover). Deeper levels only walk
        // the modal subtree to avoid traversing background content.
        if let view = root as? UIView {
            let subs = view.subviews
            if let modalIdx = subs.lastIndex(where: { $0.accessibilityViewIsModal && !$0.isHidden && $0.alpha >= 0.01 }) {
                walkAccessibilityTree(root: subs[modalIdx], depth: depth, refCounter: &refCounter,
                                      elements: &elements, modalVC: modalVC, screenBounds: screenBounds)
                if depth == 0 {
                    for i in subs.index(after: modalIdx)..<subs.endIndex {
                        if !subs[i].isHidden && subs[i].alpha >= 0.01 {
                            walkAccessibilityTree(root: subs[i], depth: depth, refCounter: &refCounter,
                                                  elements: &elements, modalVC: modalVC, screenBounds: screenBounds)
                        }
                    }
                }
                return
            }
        }

        // Three mutually exclusive child paths (AccessibilitySnapshot pattern)
        if let accElements = root.accessibilityElements as? [NSObject], !accElements.isEmpty {
            for child in accElements {
                walkAccessibilityTree(root: child, depth: depth + 1, refCounter: &refCounter,
                                      elements: &elements, modalVC: modalVC, screenBounds: screenBounds)
            }
        } else {
            let count = root.accessibilityElementCount()
            if count != NSNotFound && count > 0 {
                for i in 0..<count {
                    if let child = root.accessibilityElement(at: i) as? NSObject {
                        walkAccessibilityTree(root: child, depth: depth + 1, refCounter: &refCounter,
                                              elements: &elements, modalVC: modalVC, screenBounds: screenBounds)
                    }
                }
            } else if let view = root as? UIView {
                for subview in view.subviews {
                    walkAccessibilityTree(root: subview, depth: depth, refCounter: &refCounter,
                                          elements: &elements, modalVC: modalVC, screenBounds: screenBounds)
                }
            }
        }
    }

    // MARK: - Element Building

    private static func buildElement(
        from element: NSObject, depth: Int, refCounter: inout Int,
        modalVC: UIViewController?, screenBounds: CGRect
    ) -> NerveElement? {
        let frame = element.accessibilityFrame
        // Skip zero-frame and entirely off-screen elements
        if frame == .zero { return nil }
        if !screenBounds.intersects(frame) && frame.origin != .zero { return nil }

        let ref = "@e\(refCounter)"
        refCounter += 1

        let traits = element.accessibilityTraits
        let type = nerveAbbreviateType(element: element, traits: traits)
        let label = element.accessibilityLabel
        let identifier: String? = (element as? UIAccessibilityIdentification)?.accessibilityIdentifier
            ?? (element.responds(to: Selector(("accessibilityIdentifier")))
                ? element.value(forKey: "accessibilityIdentifier") as? String : nil)
        let value = element.accessibilityValue

        let isInteractable = traits.contains(.button) || traits.contains(.link)
            || traits.contains(.keyboardKey) || traits.contains(.adjustable)
            || traits.contains(.searchField)
            || element is UIControl || type == "field" || type == "toggle"
        let isDisabled = traits.contains(.notEnabled)

        // Find containing UIView by walking accessibilityContainer chain
        let containingView = findContainingView(for: element)

        // Activation point (may differ from frame center for custom controls)
        let activationPoint = element.accessibilityActivationPoint

        // Presentation context
        let presentationCtx: String?
        if let view = containingView, let vc = NerveViewControllerForView(view) {
            presentationCtx = presentationContext(of: vc)
        } else if let modalVC, frame.intersects(modalVC.view.accessibilityFrame) {
            presentationCtx = "modal"
        } else {
            presentationCtx = nil
        }

        // Scroll context
        let scrollCtx: String?
        if let view = containingView {
            scrollCtx = scrollContext(for: view)
        } else {
            scrollCtx = nil
        }

        // Custom accessibility actions
        let actions = (element.accessibilityCustomActions ?? []).map(\.name)

        return NerveElement(
            ref: ref, type: type, label: label, identifier: identifier, value: value,
            frame: frame, traits: traits, isInteractable: isInteractable, depth: depth,
            presentationContext: presentationCtx, scrollContext: scrollCtx,
            isDisabled: isDisabled, customActions: actions,
            rawElement: element, containingView: containingView,
            activationPoint: activationPoint
        )
    }

    // MARK: - Containing View Discovery

    /// Walk the accessibilityContainer chain upward until we find a UIView.
    private static func findContainingView(for element: NSObject) -> UIView? {
        if let view = element as? UIView { return view }

        var current: AnyObject? = element
        while let obj = current {
            // Check for .view property (many accessibility elements have this)
            if obj.responds(to: Selector(("view"))) {
                if let view = obj.value(forKey: "view") as? UIView {
                    return view
                }
            }
            // Walk up via accessibilityContainer (UIAccessibility informal protocol on NSObject)
            if obj.responds(to: Selector(("accessibilityContainer"))),
               let container = obj.perform(Selector(("accessibilityContainer")))?.takeUnretainedValue() {
                if let view = container as? UIView { return view }
                current = container
            } else {
                break
            }
        }
        return nil
    }

    // MARK: - Presentation Context

    private static func presentationContext(of vc: UIViewController) -> String? {
        if vc.presentingViewController != nil {
            switch vc.modalPresentationStyle {
            case .pageSheet, .formSheet: return "sheet"
            case .popover: return "popover"
            default: return "modal"
            }
        }
        if vc.navigationController != nil { return "navigation" }
        if vc.tabBarController != nil { return "tab" }
        return nil
    }

    // MARK: - Scroll Context

    private static func scrollContext(for view: UIView) -> String? {
        var current: UIView? = view.superview
        while let sv = current {
            if let scrollView = sv as? UIScrollView {
                let canScrollV = scrollView.contentSize.height > scrollView.bounds.height
                let canScrollH = scrollView.contentSize.width > scrollView.bounds.width
                if canScrollV && canScrollH { return "both" }
                if canScrollV { return "vertical" }
                if canScrollH { return "horizontal" }
            }
            current = sv.superview
        }
        return nil
    }

    // MARK: - UIView Hierarchy Walk

    @MainActor
    private static func walkViewHierarchy(
        root: UIView, depth: Int, refCounter: inout Int,
        elements: inout [NerveElement], existingFrames: inout Set<String>,
        modalVC: UIViewController?, screenBounds: CGRect
    ) {
        guard depth <= maxDepth else { return }
        guard elements.count < maxElements else { return }
        if root.isHidden || root.alpha < 0.01 { return }

        // Skip system windows (keyboard, status bar)
        if depth == 0, let window = root as? UIWindow {
            let cls = NSStringFromClass(type(of: window))
            if cls.contains("UITextEffects") || cls.contains("UIRemoteKeyboard") { return }
        }

        // Check if this view is interactive but was missed by accessibility walk
        let isInteractive = root is UIControl
            || (root.gestureRecognizers?.contains(where: { gr in
                !NSStringFromClass(type(of: gr)).hasPrefix("_UI") && gr.isEnabled
            }) ?? false)

        if isInteractive && root.isUserInteractionEnabled {
            let frame = root.convert(root.bounds, to: nil)
            let fk = frameKey(frame)

            // Skip if already found in accessibility walk (dedup by frame)
            if !existingFrames.contains(fk) && frame != .zero && screenBounds.intersects(frame) {
                existingFrames.insert(fk)
                let ref = "@e\(refCounter)"
                refCounter += 1

                let traits = root.accessibilityTraits
                let type = nerveAbbreviateType(element: root, traits: traits)
                let label = root.accessibilityLabel
                    ?? (root as? UIButton)?.titleLabel?.text
                    ?? (root as? UITextField)?.placeholder
                let identifier = root.accessibilityIdentifier
                let value = root.accessibilityValue
                let isDisabled = !root.isUserInteractionEnabled || traits.contains(.notEnabled)
                    || (root as? UIControl)?.isEnabled == false

                let presentationCtx: String?
                if let vc = NerveViewControllerForView(root) {
                    presentationCtx = presentationContext(of: vc)
                } else {
                    presentationCtx = nil
                }

                let el = NerveElement(
                    ref: ref, type: type, label: label, identifier: identifier, value: value,
                    frame: frame, traits: traits, isInteractable: true, depth: depth,
                    presentationContext: presentationCtx, scrollContext: scrollContext(for: root),
                    isDisabled: isDisabled, customActions: [],
                    rawElement: root, containingView: root,
                    activationPoint: {
                        let ap = root.accessibilityActivationPoint
                        return ap != .zero ? ap : CGPoint(x: frame.midX, y: frame.midY)
                    }()
                )
                elements.append(el)
            }
        }

        // Recurse into subviews
        for subview in root.subviews {
            walkViewHierarchy(
                root: subview, depth: depth + 1, refCounter: &refCounter,
                elements: &elements, existingFrames: &existingFrames,
                modalVC: modalVC, screenBounds: screenBounds
            )
        }
    }

    // MARK: - CALayer Discovery

    @MainActor
    private static func walkLayerTree(
        root: UIView, refCounter: inout Int,
        elements: inout [NerveElement], existingFrames: inout Set<String>,
        screenBounds: CGRect
    ) {
        guard elements.count < maxElements else { return }
        scanLayers(root.layer, parentView: root, refCounter: &refCounter,
                   elements: &elements, existingFrames: &existingFrames,
                   screenBounds: screenBounds, layerDepth: 0)

        for subview in root.subviews {
            walkLayerTree(root: subview, refCounter: &refCounter,
                         elements: &elements, existingFrames: &existingFrames,
                         screenBounds: screenBounds)
        }
    }

    @MainActor
    private static func scanLayers(
        _ layer: CALayer, parentView: UIView, refCounter: inout Int,
        elements: inout [NerveElement], existingFrames: inout Set<String>,
        screenBounds: CGRect, layerDepth: Int
    ) {
        guard layerDepth <= 10 else { return }
        guard elements.count < maxElements else { return }
        guard let sublayers = layer.sublayers else { return }

        for sublayer in sublayers {
            // Skip layers that have a UIView delegate (already covered by view walk)
            if sublayer.delegate is UIView { continue }

            // Classify the layer by shape heuristics
            if let (controlType, screenFrame) = classifyLayer(sublayer, parentView: parentView) {
                let fk = frameKey(screenFrame)
                if !existingFrames.contains(fk) && screenFrame != .zero && screenBounds.intersects(screenFrame) {
                    existingFrames.insert(fk)
                    let ref = "@e\(refCounter)"
                    refCounter += 1

                    let el = NerveElement(
                        ref: ref, type: controlType, label: nil, identifier: nil, value: nil,
                        frame: screenFrame, traits: .none, isInteractable: true, depth: 0,
                        presentationContext: nil, scrollContext: nil,
                        isDisabled: false, customActions: [],
                        rawElement: parentView, containingView: parentView,
                        activationPoint: CGPoint(x: screenFrame.midX, y: screenFrame.midY)
                    )
                    elements.append(el)
                }
            }

            // Recurse into sublayers
            scanLayers(sublayer, parentView: parentView, refCounter: &refCounter,
                      elements: &elements, existingFrames: &existingFrames,
                      screenBounds: screenBounds, layerDepth: layerDepth + 1)
        }
    }

    /// Classify an orphan CALayer as a known control type using shape heuristics.
    private static func classifyLayer(_ layer: CALayer, parentView: UIView) -> (String, CGRect)? {
        let bounds = layer.bounds
        let w = bounds.width
        let h = bounds.height
        guard w > 5 && h > 5 else { return nil }

        let screenFrame = parentView.convert(layer.frame, to: nil)
        let cr = layer.cornerRadius

        // Toggle capsule: fully rounded, ~51x31pt (standard iOS toggle)
        if cr >= h / 2 - 1 && w >= 45 && w <= 60 && h >= 27 && h <= 35 {
            let aspect = w / h
            if aspect >= 1.4 && aspect <= 2.2 {
                return ("toggle", screenFrame)
            }
        }

        // Slider track: very wide, thin, rounded
        if h >= 2 && h <= 6 && w > 50 && cr >= h / 2 - 1 {
            let aspect = w / h
            if aspect > 8 {
                return ("slider", screenFrame)
            }
        }

        // Slider thumb: circular, 27-33pt diameter
        if abs(w - h) < 2 && cr >= w / 2 - 2 && w >= 25 && w <= 35 {
            return ("slider", screenFrame)
        }

        return nil
    }

    // MARK: - Frame Key Helper

    private static func frameKey(_ frame: CGRect) -> String {
        "\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width)),\(Int(frame.height))"
    }

    // MARK: - Ghost Node Filtering

    private static func filterGhostNodes(_ elements: [NerveElement]) -> [NerveElement] {
        // Group elements by frame origin (rounded to 1pt)
        var originMap: [String: [Int]] = [:] // "x,y" → [indices]
        for (i, el) in elements.enumerated() {
            let key = "\(Int(el.frame.origin.x)),\(Int(el.frame.origin.y))"
            originMap[key, default: []].append(i)
        }

        var ghostIndices: Set<Int> = []
        for (_, indices) in originMap {
            if indices.count <= 1 { continue }
            // Multiple elements at same origin with different labels → keep last, ghost earlier
            let labels = indices.map { elements[$0].label }
            let uniqueLabels = Set(labels.compactMap { $0 })
            if uniqueLabels.count > 1 {
                // Keep the last index, mark earlier ones as ghosts
                for idx in indices.dropLast() {
                    ghostIndices.insert(idx)
                }
            }
        }

        return elements.enumerated().compactMap { ghostIndices.contains($0.offset) ? nil : $0.element }
    }

    // MARK: - Modal Detection

    @MainActor
    private static func findTopmostPresentedVC(in windows: [UIWindow]) -> UIViewController? {
        for window in windows.reversed() {
            guard let rootVC = window.rootViewController else { continue }
            var vc = rootVC
            while let presented = vc.presentedViewController {
                vc = presented
            }
            if vc !== rootVC { return vc }
        }
        return nil
    }

    // MARK: - Helpers

    @MainActor
    static func allWindowsPublic() -> [UIWindow] {
        var windows: [UIWindow] = []
        for scene in UIApplication.shared.connectedScenes {
            if let ws = scene as? UIWindowScene {
                windows.append(contentsOf: ws.windows)
            }
        }
        return windows
    }

    static func parseCoordinates(_ string: String) -> CGPoint? {
        let parts = string.split(separator: ",")
        guard parts.count == 2,
              let x = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Double(parts[1].trimmingCharacters(in: .whitespaces)) else { return nil }
        return CGPoint(x: x, y: y)
    }
}

#endif
