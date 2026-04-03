#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - View Hierarchy

/// Returns all windows including internal ones (keyboard, alerts, status bar).
/// Uses the private +[UIWindow allWindowsIncludingInternalWindows:onlyVisibleWindows:] API.
NSArray<UIWindow *> *NerveGetAllWindows(void);

/// Returns the view controller associated with a view via the responder chain.
UIViewController * _Nullable NerveViewControllerForView(UIView *view);

/// Finds the topmost visible window at a given screen-space point.
/// Returns nil if no window contains that point.
UIWindow * _Nullable NerveFindWindowAtPoint(CGPoint screenPoint);

#pragma mark - Touch Synthesis

/// Synthesizes a tap at the given point in the window's coordinate system.
/// Uses IOHIDEvent injection for touch synthesis.
/// @param point The tap location in window coordinates.
/// @param window The window to dispatch the event to.
/// @return YES if the tap was dispatched successfully.
BOOL NerveSynthesizeTap(CGPoint point, UIWindow *window);

/// Synthesizes a long press at the given point.
/// @param point The press location in window coordinates.
/// @param duration Duration of the long press in seconds.
/// @param window The window to dispatch the event to.
/// @return YES if dispatched successfully.
BOOL NerveSynthesizeLongPress(CGPoint point, NSTimeInterval duration, UIWindow *window);

/// Synthesizes a multi-point drag (for scrolling/swiping).
/// @param points Array of NSValue-wrapped CGPoints in window coordinates.
/// @param duration Total duration of the drag in seconds.
/// @param window The window to dispatch events to.
/// @return YES if the drag was dispatched successfully.
BOOL NerveSynthesizeDrag(NSArray<NSValue *> *points, NSTimeInterval duration, UIWindow *window);

/// Synthesizes a double tap at the given point.
BOOL NerveSynthesizeDoubleTap(CGPoint point, UIWindow *window);

/// Synthesizes a drag-and-drop: long press at start, drag to end, release.
/// @param start The pickup location.
/// @param end The drop location.
/// @param holdDuration How long to hold before dragging (seconds). Default 0.5.
/// @param dragDuration How long the drag takes (seconds). Default 0.5.
BOOL NerveSynthesizeDragDrop(CGPoint start, CGPoint end, NSTimeInterval holdDuration,
                              NSTimeInterval dragDuration, UIWindow *window);

/// Synthesizes a two-finger pinch gesture.
/// @param center The center point of the pinch.
/// @param startDistance Distance between fingers at start (points).
/// @param endDistance Distance between fingers at end (points). > start = zoom in, < start = zoom out.
/// @param duration Gesture duration in seconds.
BOOL NerveSynthesizePinch(CGPoint center, CGFloat startDistance, CGFloat endDistance,
                           NSTimeInterval duration, UIWindow *window);

#pragma mark - Heap Inspection

/// Finds all live instances of the given class on the heap.
/// Uses malloc zone enumeration.
/// @param className The name of the class to search for.
/// @param limit Maximum number of instances to return.
/// @return Array of live objects matching the class.
NSArray *NerveHeapInstances(NSString *className, NSUInteger limit);

/// Validates that a pointer is a valid Objective-C object.
BOOL NervePointerIsValidObject(const void *ptr);

#pragma mark - Network Interception

/// Starts intercepting HTTP traffic via URLProtocol + config swizzling.
void NerveStartNetworkInterception(void);

/// Stops intercepting HTTP traffic.
void NerveStopNetworkInterception(void);

#pragma mark - Property Inspection

/// Lists all properties of a class (including superclasses, excluding NSObject).
/// Returns a dictionary of property name → type encoding string.
NSDictionary<NSString *, NSString *> *NerveListProperties(Class cls);

#pragma mark - Runtime Utilities

/// Reads a property value from an object using KVC, returning nil on failure.
id _Nullable NerveReadProperty(id object, NSString *keyPath);

/// Returns the class name, demangling Swift names if needed.
NSString *NerveClassName(id object);

/// Returns YES if the object is a Swift class (not pure ObjC).
BOOL NerveIsSwiftObject(id object);

#pragma mark - Accessibility

/// Enables the accessibility automation subsystem.
/// Must be called before walking SwiftUI accessibility trees.
/// Uses _AXSSetAutomationEnabled from libAccessibility.dylib (private API, debug only).
void NerveEnableAccessibility(void);

/// Posts VoiceOver status change and screen/layout change notifications
/// to trigger SwiftUI to populate lazy accessibility trees.
void NervePostAccessibilityNotifications(void);

#pragma mark - Auto-Tagging

/// Assigns accessibility identifiers to interactive elements that lack them.
/// Called automatically on viewDidAppear via swizzle.
/// Tags: buttons (button_title), text fields (textfield_placeholder),
/// switches (switch_N), cells (cell_text), labels (label_text).
void NerveAutoTagElements(UIView *rootView);

/// Installs a swizzle on viewDidAppear to auto-tag elements when screens appear.
void NerveInstallAutoTagging(void);

#pragma mark - Navigation Observation

/// Callback type for navigation transitions.
/// Parameters: fromVC class name, toVC class name, action ("push"/"present"/"tab"/"appear").
typedef void (*NerveNavCallback)(NSString *from, NSString *to, NSString *action);

/// Installs swizzles on UINavigationController, UIViewController, UITabBarController
/// to record all navigation transitions.
void NerveInstallNavigationSwizzles(NerveNavCallback callback);

#pragma mark - Method Tracing

/// Callback type for method trace events.
/// Parameters: class name, method name, args description.
typedef void (*NerveTraceCallback)(NSString *className, NSString *methodName, NSString *args);

/// Installs a tracing swizzle on a method. All calls will be logged via the callback.
/// @param className The class to trace.
/// @param methodName The selector name (e.g., "viewDidAppear:").
/// @param isClassMethod YES for class methods (+), NO for instance methods (-).
/// @param callback Called on every invocation.
/// @return YES if the swizzle was installed successfully.
BOOL NerveInstallTrace(NSString *className, NSString *methodName, BOOL isClassMethod,
                       NerveTraceCallback callback);

/// Removes a previously installed trace.
/// @return YES if the trace was found and removed.
BOOL NerveRemoveTrace(NSString *className, NSString *methodName, BOOL isClassMethod);

/// Removes all installed traces.
void NerveRemoveAllTraces(void);

/// Returns the number of active traces.
NSUInteger NerveActiveTraceCount(void);

#pragma mark - Bootstrap (dylib injection)

/// Called by __attribute__((constructor)) in NerveBootstrap.c.
/// Starts the framework when injected via DYLD_INSERT_LIBRARIES.
void nerve_framework_init(void);

#pragma mark - Debug

/// Install sendEvent: swizzle to log touch delivery
void NerveInstallSendEventLogging(void);
void NerveEnableSendEventLogging(BOOL enabled);

NS_ASSUME_NONNULL_END
