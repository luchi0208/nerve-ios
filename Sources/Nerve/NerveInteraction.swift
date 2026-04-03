#if DEBUG

import UIKit
import NerveObjC
import os

// MARK: - Interaction Commands

extension NerveEngine {

    // MARK: - Tap

    func handleTap(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }

        lastActionTime = Date()

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async { [self] in
                // 1. Resolve to a point
                let point: CGPoint
                let desc: String

                if let coords = NerveElementResolver.parseCoordinates(query) {
                    point = coords
                    desc = "\(Int(coords.x)),\(Int(coords.y))"

                    // For coordinate taps, check if the point hits a UIAlertController action.
                    // HID synthetic touches create indirect UITouch (type=1) which alert
                    // gesture recognizers reject. Use KVC invocation instead.
                    if let alertLabel = self.alertActionLabel(at: coords),
                       let result = self.invokeAlertAction(label: alertLabel) {
                        NerveElementResolver.invalidateCache()
                        continuation.resume(returning: .success(command.id, result))
                        return
                    }
                } else {
                    guard let element = NerveElementResolver.resolve(query: query) else {
                        continuation.resume(returning: .error(command.id, "Element not found: '\(query)'"))
                        return
                    }
                    if element.isDisabled {
                        continuation.resume(returning: .error(command.id, "Element '\(query)' is disabled"))
                        return
                    }
                    self.navMap.lastTappedElement = (label: element.label, identifier: element.identifier)

                    // Alert/action sheet buttons don't respond to HID events.
                    // HID synthetic touches create indirect UITouch (type=1) which alert
                    // gesture recognizers (_UIInterfaceActionSelectByPressGestureRecognizer) reject.
                    // Invoke the UIAlertAction handler directly via KVC.
                    if element.presentationContext == "modal" || element.presentationContext == "popover" {
                        if let result = self.invokeAlertAction(label: element.label) {
                            NerveElementResolver.invalidateCache()
                            continuation.resume(returning: .success(command.id, result))
                            return
                        }
                    }

                    point = element.activationPoint
                    desc = element.identifier.map { "#\($0)" } ?? element.label.map { "'\($0)'" } ?? element.type
                    guard point != .zero else {
                        continuation.resume(returning: .error(command.id, "Element '\(query)' has no activation point"))
                        return
                    }
                }

                // 2. Find the correct window (topmost first)
                let window = NerveFindWindowAtPoint(point)
                    ?? (NerveGetAllWindows() as? [UIWindow])?.first

                guard let window else {
                    continuation.resume(returning: .error(command.id, "No window available"))
                    return
                }

                // 3. HID tap
                NerveSynthesizeTap(point, window)
                NerveEngine.showTapIndicator(at: point, in: window)
                NerveElementResolver.invalidateCache()
                continuation.resume(returning: .success(command.id, "Tapped \(desc) at \(Int(point.x)),\(Int(point.y))"))
            }
        }
    }

    // MARK: - Long Press

    func handleLongPress(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }

        let duration = command.doubleParam("duration") ?? 1.0
        lastActionTime = Date()

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let element = NerveElementResolver.resolve(query: query) else {
                    continuation.resume(returning: .error(command.id, "Element not found: '\(query)'"))
                    return
                }

                let point = element.activationPoint
                guard point != .zero else {
                    continuation.resume(returning: .error(command.id, "Could not long-press '\(query)'"))
                    return
                }
                let window = NerveFindWindowAtPoint(point)
                    ?? element.containingView?.window
                    ?? (NerveGetAllWindows() as? [UIWindow])?.first
                guard let window else {
                    continuation.resume(returning: .error(command.id, "No window available"))
                    return
                }

                let windowPoint = window.convert(point, from: nil)
                NerveSynthesizeLongPress(windowPoint, duration, window)
                NerveElementResolver.invalidateCache()
                let desc = element.identifier.map { "#\($0)" } ?? element.label.map { "'\($0)'" } ?? element.type
                continuation.resume(returning: .success(command.id, "Long-pressed \(desc) for \(duration)s"))
            }
        }
    }

    // MARK: - Scroll

    @MainActor
    func handleScroll(_ command: NerveCommand) async -> NerveResponse {
        guard let direction = command.stringParam("direction") else {
            return .error(command.id, "Missing 'direction' parameter")
        }
        lastActionTime = Date()

        let amount = command.doubleParam("amount") ?? 300.0
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        guard let window = windows.first else {
            return .error(command.id, "No window available")
        }

        // Find the frontmost scroll view across all windows
        var scrollView: UIScrollView?
        for w in windows.reversed() {
            if let sv = findScrollView(in: w) {
                scrollView = sv
                break
            }
        }

        if let scrollView {
            var offset = scrollView.contentOffset
            switch direction {
            case "up": offset.y = max(offset.y - CGFloat(amount), -scrollView.contentInset.top)
            case "down": offset.y = min(offset.y + CGFloat(amount), scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            case "left": offset.x = max(offset.x - CGFloat(amount), -scrollView.contentInset.left)
            case "right": offset.x = min(offset.x + CGFloat(amount), scrollView.contentSize.width - scrollView.bounds.width + scrollView.contentInset.right)
            default: return .error(command.id, "Invalid direction: '\(direction)'. Use up/down/left/right.")
            }
            scrollView.setContentOffset(offset, animated: true)
            NerveElementResolver.invalidateCache()
            return .success(command.id, "Scrolled \(direction) by \(Int(amount))pt")
        }

        // Fallback: synthesize drag
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        var endPoint = center
        switch direction {
        case "up": endPoint.y += CGFloat(amount)
        case "down": endPoint.y -= CGFloat(amount)
        case "left": endPoint.x += CGFloat(amount)
        case "right": endPoint.x -= CGFloat(amount)
        default: return .error(command.id, "Invalid direction: '\(direction)'")
        }

        let points = [
            NSValue(cgPoint: center),
            NSValue(cgPoint: CGPoint(x: (center.x + endPoint.x) / 2, y: (center.y + endPoint.y) / 2)),
            NSValue(cgPoint: endPoint),
        ]
        NerveSynthesizeDrag(points, 0.3, window)
        NerveElementResolver.invalidateCache()
        return .success(command.id, "Scrolled \(direction) by \(Int(amount))pt (drag)")
    }

    // MARK: - Swipe

    @MainActor
    func handleSwipe(_ command: NerveCommand) async -> NerveResponse {
        guard let direction = command.stringParam("direction") else {
            return .error(command.id, "Missing 'direction' parameter")
        }
        lastActionTime = Date()

        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        guard let window = windows.first else {
            return .error(command.id, "No window available")
        }

        let start: CGPoint
        if let fromStr = command.stringParam("from"), let pt = NerveElementResolver.parseCoordinates(fromStr) {
            start = pt
        } else {
            start = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        }

        let swipeDistance: CGFloat = 200
        var end = start
        switch direction {
        case "up": end.y -= swipeDistance
        case "down": end.y += swipeDistance
        case "left": end.x -= swipeDistance
        case "right": end.x += swipeDistance
        default: return .error(command.id, "Invalid direction: '\(direction)'")
        }

        let swipeWindow = NerveFindWindowAtPoint(start) ?? window
        let points = [NSValue(cgPoint: start), NSValue(cgPoint: end)]
        NerveSynthesizeDrag(points, 0.15, swipeWindow)
        NerveElementResolver.invalidateCache()
        return .success(command.id, "Swiped \(direction)")
    }

    // MARK: - Type

    @MainActor
    func handleType(_ command: NerveCommand) async -> NerveResponse {
        guard let text = command.stringParam("text") else {
            return .error(command.id, "Missing 'text' parameter")
        }
        lastActionTime = Date()

        // Find the first responder
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        guard let firstResponder = findFirstResponder(in: windows) else {
            return .error(command.id, "No text field is focused. Tap a text field first.")
        }

        if let textInput = firstResponder as? UITextInput {
            if let range = textInput.selectedTextRange {
                textInput.replace(range, withText: text)
            }
            // Fire editing changed for SwiftUI binding updates
            if let tf = firstResponder as? UITextField {
                tf.sendActions(for: .editingChanged)
            }
        } else if let textField = firstResponder as? UITextField {
            textField.text = (textField.text ?? "") + text
            textField.sendActions(for: .editingChanged)
        } else if let textView = firstResponder as? UITextView {
            textView.insertText(text)
        } else if let keyInput = firstResponder as? UIKeyInput {
            for char in text { keyInput.insertText(String(char)) }
        } else {
            return .error(command.id, "Focused element doesn't accept text input")
        }

        let submit = command.boolParam("submit") ?? false
        if submit {
            if let textField = firstResponder as? UITextField {
                textField.sendActions(for: .editingDidEndOnExit)
            } else if let keyInput = firstResponder as? UIKeyInput {
                keyInput.insertText("\n")
            }
        }

        return .success(command.id, "Typed \"\(text)\"\(submit ? " and submitted" : "")")
    }

    // MARK: - Double Tap

    func handleDoubleTap(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }
        lastActionTime = Date()

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                if let point = NerveElementResolver.parseCoordinates(query) {
                    let window = NerveFindWindowAtPoint(point)
                        ?? (NerveGetAllWindows() as? [UIWindow])?.first
                    guard let window else {
                        continuation.resume(returning: .error(command.id, "No window"))
                        return
                    }
                    NerveSynthesizeDoubleTap(point, window)
                    NerveElementResolver.invalidateCache()
                    continuation.resume(returning: .success(command.id, "Double-tapped at \(Int(point.x)),\(Int(point.y))"))
                    return
                }

                guard let element = NerveElementResolver.resolve(query: query) else {
                    continuation.resume(returning: .error(command.id, "Element not found: '\(query)'"))
                    return
                }

                let point = element.activationPoint
                let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
                let window = NerveFindWindowAtPoint(point)
                    ?? element.containingView?.window
                    ?? windows.first
                guard point != .zero, let window else {
                    continuation.resume(returning: .error(command.id, "No activation point"))
                    return
                }

                NerveSynthesizeDoubleTap(point, window)
                NerveElementResolver.invalidateCache()
                let desc = element.identifier.map { "#\($0)" } ?? element.label.map { "'\($0)'" } ?? element.type
                continuation.resume(returning: .success(command.id, "Double-tapped \(desc)"))
            }
        }
    }

    // MARK: - Drag and Drop

    func handleDragDrop(_ command: NerveCommand) async -> NerveResponse {
        guard let fromQuery = command.stringParam("from") else {
            return .error(command.id, "Missing 'from' parameter")
        }
        guard let toQuery = command.stringParam("to") else {
            return .error(command.id, "Missing 'to' parameter")
        }
        let holdDuration = command.doubleParam("hold_duration") ?? 0.5
        let dragDuration = command.doubleParam("drag_duration") ?? 0.5
        lastActionTime = Date()

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()

                let fromPoint: CGPoint
                if let pt = NerveElementResolver.parseCoordinates(fromQuery) {
                    fromPoint = pt
                } else if let el = NerveElementResolver.resolve(query: fromQuery) {
                    fromPoint = el.activationPoint
                } else {
                    continuation.resume(returning: .error(command.id, "Source not found: '\(fromQuery)'"))
                    return
                }

                let toPoint: CGPoint
                if let pt = NerveElementResolver.parseCoordinates(toQuery) {
                    toPoint = pt
                } else if let el = NerveElementResolver.resolve(query: toQuery) {
                    toPoint = el.activationPoint
                } else {
                    continuation.resume(returning: .error(command.id, "Target not found: '\(toQuery)'"))
                    return
                }

                let window = NerveFindWindowAtPoint(fromPoint) ?? windows.first
                guard let window else {
                    continuation.resume(returning: .error(command.id, "No window"))
                    return
                }

                NerveSynthesizeDragDrop(fromPoint, toPoint, holdDuration, dragDuration, window)
                NerveElementResolver.invalidateCache()
                continuation.resume(returning: .success(command.id, "Dragged from \(Int(fromPoint.x)),\(Int(fromPoint.y)) to \(Int(toPoint.x)),\(Int(toPoint.y))"))
            }
        }
    }

    // MARK: - Pull to Refresh

    @MainActor
    func handlePullToRefresh(_ command: NerveCommand) async -> NerveResponse {
        lastActionTime = Date()

        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        guard let window = windows.first else {
            return .error(command.id, "No window")
        }

        // Find the frontmost scroll view across all windows
        var scrollView: UIScrollView?
        for w in windows.reversed() {
            if let sv = findScrollView(in: w) {
                scrollView = sv
                break
            }
        }
        guard let scrollView else {
            return .error(command.id, "No scroll view found")
        }

        let scrollFrame = scrollView.convert(scrollView.bounds, to: nil)
        let startY = scrollFrame.origin.y + 80 // Start near top of scroll view
        let startPoint = CGPoint(x: scrollFrame.midX, y: startY)
        let endPoint = CGPoint(x: scrollFrame.midX, y: startY + 250) // Drag down 250pt

        // Slow drag down (0.6s) to trigger pull-to-refresh
        let points = [
            NSValue(cgPoint: startPoint),
            NSValue(cgPoint: CGPoint(x: startPoint.x, y: startPoint.y + 80)),
            NSValue(cgPoint: CGPoint(x: startPoint.x, y: startPoint.y + 160)),
            NSValue(cgPoint: endPoint),
        ]
        NerveSynthesizeDrag(points, 0.6, window)
        NerveElementResolver.invalidateCache()

        return .success(command.id, "Pull to refresh from \(Int(startPoint.y)) to \(Int(endPoint.y))")
    }

    // MARK: - Pinch / Zoom

    func handlePinch(_ command: NerveCommand) async -> NerveResponse {
        let scale = command.doubleParam("scale") ?? 2.0
        lastActionTime = Date()

        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
                guard let fallbackWindow = windows.first else {
                    continuation.resume(returning: .error(command.id, "No window"))
                    return
                }

                let center: CGPoint
                if let query = command.stringParam("query") {
                    if let pt = NerveElementResolver.parseCoordinates(query) {
                        center = pt
                    } else if let el = NerveElementResolver.resolve(query: query) {
                        center = el.activationPoint
                    } else {
                        center = CGPoint(x: fallbackWindow.bounds.midX, y: fallbackWindow.bounds.midY)
                    }
                } else {
                    center = CGPoint(x: fallbackWindow.bounds.midX, y: fallbackWindow.bounds.midY)
                }

                let window = NerveFindWindowAtPoint(center) ?? fallbackWindow

                let startDistance: CGFloat = 100
                let endDistance = startDistance * CGFloat(scale)
                let duration: TimeInterval = 0.5

                NerveSynthesizePinch(center, startDistance, endDistance, duration, window)
                NerveElementResolver.invalidateCache()

                let action = scale > 1 ? "Zoomed in" : "Zoomed out"
                continuation.resume(returning: .success(command.id, "\(action) \(scale)x at \(Int(center.x)),\(Int(center.y))"))
            }
        }
    }

    // MARK: - Context Menu

    func handleContextMenu(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }
        lastActionTime = Date()

        // Long press to trigger context menu
        let lpCommand = NerveCommand(
            id: command.id,
            command: "long_press",
            params: [
                "query": AnyCodable(query),
                "duration": AnyCodable(0.8),
            ]
        )
        let lpResult = await handleLongPress(lpCommand)
        if !lpResult.ok { return lpResult }

        // Look at the screen to find menu items
        let lookCommand = NerveCommand(id: command.id, command: "view", params: nil)
        let lookResult = await handleView(lookCommand)

        return .success(command.id, "Context menu opened. Screen:\n\(lookResult.body)")
    }

    // MARK: - Back

    @MainActor
    func handleBack(_ command: NerveCommand) async -> NerveResponse {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()

        // Check for presented VC first (dismiss modal/sheet)
        if let window = windows.first, let topVC = topViewController(in: window) {
            if topVC.presentingViewController != nil {
                topVC.dismiss(animated: true)
                NerveElementResolver.invalidateCache()
                NervePostAccessibilityNotifications()
                return .success(command.id, "Dismissed \(NerveClassName(topVC))")
            }
        }

        // Find UINavigationController and pop
        if let nav = findNavigationController(in: windows), nav.viewControllers.count > 1 {
            nav.popViewController(animated: true)
            NerveElementResolver.invalidateCache()
            NervePostAccessibilityNotifications()
            let current = nav.viewControllers.last.map { NerveClassName($0) } ?? "previous"
            return .success(command.id, "Popped navigation to \(current)")
        }

        return .error(command.id, "Nothing to go back from")
    }

    // MARK: - Dismiss

    @MainActor
    func handleDismiss(_ command: NerveCommand) async -> NerveResponse {
        // Dismiss keyboard first (only if an actual text input is focused)
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        if findFirstResponder(in: windows) is UITextInput {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            return .success(command.id, "Dismissed keyboard")
        }

        // Dismiss presented VC
        if let window = windows.first, let topVC = topViewController(in: window), topVC.presentingViewController != nil {
            topVC.dismiss(animated: true)
            NerveElementResolver.invalidateCache()
            NervePostAccessibilityNotifications()
            return .success(command.id, "Dismissed \(NerveClassName(topVC))")
        }

        return .success(command.id, "Nothing to dismiss")
    }

    // MARK: - Custom Action (#15)

    @MainActor
    func handleAction(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }
        guard let actionName = command.stringParam("action") else {
            return .error(command.id, "Missing 'action' parameter (name of the custom accessibility action)")
        }

        guard let element = NerveElementResolver.resolve(query: query) else {
            return .error(command.id, "Element not found: '\(query)'")
        }

        guard let raw = element.rawElement else {
            return .error(command.id, "Element has no backing object")
        }

        guard let actions = raw.accessibilityCustomActions, !actions.isEmpty else {
            return .error(command.id, "Element '\(query)' has no custom actions")
        }

        guard let action = actions.first(where: { $0.name == actionName })
                ?? actions.first(where: { $0.name.localizedCaseInsensitiveContains(actionName) }) else {
            let available = actions.map(\.name).joined(separator: ", ")
            return .error(command.id, "Action '\(actionName)' not found. Available: \(available)")
        }

        // Invoke the action
        let result: Bool
        if let target = action.target {
            let returnValue = target.perform(action.selector, with: action)
            result = (returnValue?.takeUnretainedValue() as? NSNumber)?.boolValue ?? true
        } else {
            // Block-based action — call accessibilityActivate as fallback
            result = raw.accessibilityActivate()
        }

        NerveElementResolver.invalidateCache()
        return .success(command.id, result ? "Performed '\(actionName)'" : "Action '\(actionName)' returned false")
    }

    // MARK: - Scroll to Find

    @MainActor
    func handleScrollToFind(_ command: NerveCommand) async -> NerveResponse {
        guard let query = command.stringParam("query") else {
            return .error(command.id, "Missing 'query' parameter")
        }

        let maxAttempts = command.intParam("max_attempts") ?? 10

        if let element = NerveElementResolver.scrollToFind(query: query, maxAttempts: maxAttempts) {
            return .success(command.id, "Found '\(query)' after scrolling: \(element.type) \(element.label ?? "") at \(Int(element.frame.origin.x)),\(Int(element.frame.origin.y))")
        }

        return .error(command.id, "Element '\(query)' not found after scrolling \(maxAttempts) pages")
    }

    // MARK: - Wait Idle

    @MainActor
    func handleWaitIdle(_ command: NerveCommand) async -> NerveResponse {
        let timeout = command.doubleParam("timeout") ?? 5.0
        let quiet = command.doubleParam("quiet") ?? 1.0

        let startTime = Date()
        var lastEventTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let pendingNetwork = NerveNetworkStore.shared.pendingCount
            let hasAnimations = checkForRunningAnimations()

            if pendingNetwork > 0 || hasAnimations {
                lastEventTime = Date()
            }

            let quietElapsed = Date().timeIntervalSince(lastEventTime)
            if pendingNetwork == 0 && !hasAnimations && quietElapsed >= quiet {
                let elapsed = Int(Date().timeIntervalSince(startTime) * 1000)
                return .success(command.id, "Idle after \(elapsed)ms")
            }

            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        let pending = NerveNetworkStore.shared.pendingCount
        let anims = checkForRunningAnimations()
        var reasons: [String] = []
        if pending > 0 { reasons.append("\(pending) pending network request(s)") }
        if anims { reasons.append("animations running") }

        let elapsed = Int(timeout * 1000)
        if reasons.isEmpty {
            return .success(command.id, "Idle after \(elapsed)ms (timeout)")
        }
        return .success(command.id, "Timeout after \(elapsed)ms. Still pending: \(reasons.joined(separator: ", "))")
    }

    // MARK: - Tab Switching

    /// Switch to a tab by matching the tab item's title.
    @MainActor
    private func switchTabByLabel(_ label: String) -> Bool {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        for window in windows {
            if let tbc = findTabBarControllerInVC(window.rootViewController) {
                guard let vcs = tbc.viewControllers else { continue }
                for (idx, vc) in vcs.enumerated() {
                    if vc.tabBarItem.title == label
                        || vc.tabBarItem.title?.localizedCaseInsensitiveContains(label) == true {
                        tbc.selectedIndex = idx
                        return true
                    }
                }
            }
        }
        return false
    }

    private func findTabBarControllerInVC(_ vc: UIViewController?) -> UITabBarController? {
        guard let vc else { return nil }
        if let tbc = vc as? UITabBarController { return tbc }
        if let presented = vc.presentedViewController {
            if let tbc = findTabBarControllerInVC(presented) { return tbc }
        }
        for child in vc.children {
            if let tbc = findTabBarControllerInVC(child) { return tbc }
        }
        return nil
    }

    // MARK: - Helpers

    @MainActor
    private func checkForRunningAnimations() -> Bool {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        for window in windows {
            // Skip the tap indicator overlay window
            if window.windowLevel.rawValue > UIWindow.Level.alert.rawValue { continue }
            if hasAnimations(in: window.layer) { return true }
        }
        return false
    }

    private func hasAnimations(in layer: CALayer) -> Bool {
        if let keys = layer.animationKeys(), !keys.isEmpty {
            let hasTransientAnimation = keys.contains { key in
                guard let anim = layer.animation(forKey: key) else { return true }
                // Skip permanent/decorative animations
                if anim.duration.isInfinite || anim.duration > 1e9 { return false }
                if anim.repeatCount.isInfinite || anim.repeatCount > 100 { return false }
                if anim.repeatDuration.isInfinite { return false }
                return true
            }
            if hasTransientAnimation { return true }
        }
        for sublayer in layer.sublayers ?? [] {
            if hasAnimations(in: sublayer) { return true }
        }
        return false
    }

    // MARK: - Auto-Wait for UI Settle

    /// Waits for the UI to settle after an interaction.
    /// Checks animations and VC transitions. Does NOT wait for network.
    @MainActor
    func waitForUIToSettle(timeout: TimeInterval = 0.4, quietPeriod: TimeInterval = 0.05) async {
        let startTime = Date()
        let pollInterval: TimeInterval = 0.02
        var sawActivity = false

        while Date().timeIntervalSince(startTime) < timeout {
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))

            if checkForRunningAnimations() {
                sawActivity = true
            } else if sawActivity {
                // Animations stopped — wait quiet period then return
                RunLoop.current.run(until: Date().addingTimeInterval(quietPeriod))
                return
            } else {
                // No animations at all — return immediately
                return
            }
        }
    }

    @MainActor
    private func checkForActiveTransitions() -> Bool {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        for window in windows {
            if hasActiveTransition(from: window.rootViewController) {
                return true
            }
        }
        return false
    }

    private func hasActiveTransition(from vc: UIViewController?) -> Bool {
        guard let vc else { return false }
        if vc.transitionCoordinator != nil { return true }
        if let presented = vc.presentedViewController {
            if hasActiveTransition(from: presented) { return true }
        }
        for child in vc.children {
            if hasActiveTransition(from: child) { return true }
        }
        return false
    }

    func findScrollView(in view: UIView) -> UIScrollView? {
        if let sv = view as? UIScrollView, !(sv is UITextView) { return sv }
        for subview in view.subviews.reversed() {
            if let found = findScrollView(in: subview) { return found }
        }
        return nil
    }

    private func findFirstResponder(in windows: [UIWindow]) -> UIView? {
        for window in windows {
            if let responder = findFirstResponderInView(window) { return responder }
        }
        return nil
    }

    private func findFirstResponderInView(_ view: UIView) -> UIView? {
        if view.isFirstResponder { return view }
        for subview in view.subviews {
            if let found = findFirstResponderInView(subview) { return found }
        }
        return nil
    }

    func topViewController(in window: UIWindow) -> UIViewController? {
        var vc = window.rootViewController
        while let presented = vc?.presentedViewController { vc = presented }
        if let nav = vc as? UINavigationController { vc = nav.topViewController }
        if let tab = vc as? UITabBarController { vc = tab.selectedViewController }
        if let nav = vc as? UINavigationController { vc = nav.topViewController }
        return vc
    }

    private func findNavigationController(in windows: [UIWindow]) -> UINavigationController? {
        for window in windows {
            if let nav = findNavController(from: window.rootViewController) { return nav }
        }
        return nil
    }

    private func findNavController(from vc: UIViewController?) -> UINavigationController? {
        guard let vc else { return nil }
        // Check presented first
        if let presented = vc.presentedViewController {
            if let nav = findNavController(from: presented) { return nav }
        }
        if let nav = vc as? UINavigationController, nav.viewControllers.count > 1 { return nav }
        if let tab = vc as? UITabBarController {
            if let nav = findNavController(from: tab.selectedViewController) { return nav }
        }
        for child in vc.children {
            if let nav = findNavController(from: child) { return nav }
        }
        return nil
    }
    // MARK: - Alert Action Invocation

    /// Find the accessibility label of a UIAlertController action view at a screen point.
    /// Returns nil if the point doesn't hit an alert action view.
    @MainActor
    private func alertActionLabel(at point: CGPoint) -> String? {
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        for window in windows.reversed() {
            let wp = window.convert(point, from: nil)
            guard let hit = window.hitTest(wp, with: nil) else { continue }
            // Walk up the view hierarchy looking for _UIAlertControllerActionView
            var view: UIView? = hit
            while let v = view {
                if NSStringFromClass(type(of: v)).contains("AlertControllerActionView") {
                    return v.accessibilityLabel
                }
                view = v.superview
            }
        }
        return nil
    }

    /// Invoke a UIAlertAction handler directly via KVC.
    /// HID touch synthesis doesn't work on alert buttons — their gesture
    /// recognizers (_UIInterfaceActionSelectByPressGestureRecognizer) reject
    /// indirect UITouch events (type=1) created by HID synthesis.
    @MainActor
    private func invokeAlertAction(label: String?) -> String? {
        guard let label else { return nil }
        let windows = NerveGetAllWindows() as? [UIWindow] ?? NerveElementResolver.allWindowsPublic()
        for window in windows.reversed() {
            guard let topVC = topViewController(in: window) else { continue }
            guard let alert = topVC as? UIAlertController ?? topVC.presentedViewController as? UIAlertController else { continue }
            guard let action = alert.actions.first(where: { $0.title == label }) else { continue }

            typealias ActionHandler = @convention(block) (UIAlertAction) -> Void
            alert.dismiss(animated: false) {
                if let handler = action.value(forKey: "handler") {
                    let block = unsafeBitCast(handler as AnyObject, to: ActionHandler.self)
                    block(action)
                }
            }
            return "Tapped '\(label)'"
        }
        return nil
    }

    // MARK: - Tap Indicator

    @MainActor
    static func showTapIndicator(at point: CGPoint, in window: UIWindow) {
        os_log("[Nerve] showTapIndicator called at %d,%d", Int(point.x), Int(point.y))
        os_log("[Nerve] window: %{public}@, windowScene: %{public}@", "\(window)", "\(String(describing: window.windowScene))")

        guard let scene = window.windowScene else {
            os_log("[Nerve] showTapIndicator: no windowScene, aborting")
            return
        }

        os_log("[Nerve] creating overlay window on scene: %{public}@", "\(scene)")

        let size: CGFloat = 44
        let indicator = UIView(frame: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size))
        indicator.backgroundColor = UIColor.systemRed.withAlphaComponent(0.5)
        indicator.layer.cornerRadius = size / 2
        indicator.layer.borderWidth = 3
        indicator.layer.borderColor = UIColor.systemRed.cgColor
        indicator.isUserInteractionEnabled = false

        // Use an overlay window with windowScene to ensure visibility above modals/sheets
        let overlayWindow = UIWindow(windowScene: scene)
        overlayWindow.windowLevel = .alert + 1
        overlayWindow.isUserInteractionEnabled = false
        overlayWindow.backgroundColor = .clear
        overlayWindow.isHidden = false
        overlayWindow.addSubview(indicator)

        indicator.transform = CGAffineTransform(scaleX: 1.8, y: 1.8)
        indicator.alpha = 0

        UIView.animate(withDuration: 0.15, delay: 0, options: .curveEaseOut) {
            indicator.alpha = 1
            indicator.transform = .identity
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0.2, options: .curveEaseIn) {
                indicator.alpha = 0
                indicator.transform = CGAffineTransform(scaleX: 2.0, y: 2.0)
            } completion: { _ in
                overlayWindow.isHidden = true
            }
        }
    }
}

#endif
