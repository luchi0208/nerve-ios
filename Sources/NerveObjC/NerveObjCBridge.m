#import "NerveObjCBridge.h"

#if DEBUG

#import <objc/runtime.h>
#import <objc/message.h>
#import <malloc/malloc.h>
#import <mach/mach.h>
#import <dlfcn.h>
#import <os/log.h>

// MARK: - View Hierarchy

NSArray<UIWindow *> *NerveGetAllWindows(void) {
    // Build the obfuscated selector for the private API:
    // +[UIWindow allWindowsIncludingInternalWindows:onlyVisibleWindows:]
    NSArray *fragments = @[@"al", @"lWindo", @"wsIncl", @"udingInt",
                           @"ernalWin", @"dows:o", @"nlyVisi", @"bleWin", @"dows:"];
    SEL sel = NSSelectorFromString([fragments componentsJoinedByString:@""]);

    if (![UIWindow respondsToSelector:sel]) {
        // Fallback: use public scene API
        NSMutableArray<UIWindow *> *windows = [NSMutableArray new];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                [windows addObjectsFromArray:((UIWindowScene *)scene).windows];
            }
        }
        return windows;
    }

    // Call the private API: +[UIWindow allWindowsIncludingInternalWindows:YES onlyVisibleWindows:NO]
    BOOL includeInternal = YES;
    BOOL onlyVisible = NO;
    NSArray *result = ((NSArray *(*)(id, SEL, BOOL, BOOL))objc_msgSend)(
        [UIWindow class], sel, includeInternal, onlyVisible
    );
    return result ?: @[];
}

UIViewController *NerveViewControllerForView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

// MARK: - Touch Synthesis

// --- IOHIDEvent types and functions (from IOKit, works on both simulator and device) ---

typedef void *IOHIDEventRef;
typedef uint32_t IOHIDEventType;
typedef uint32_t IOHIDEventField;
typedef double IOHIDFloat;

enum {
    kIOHIDDigitizerTransducerTypeHand = 0x3,
    kIOHIDDigitizerTransducerTypeFinger = 0x2,
    kIOHIDDigitizerEventRange = 0x1,
    kIOHIDDigitizerEventTouch = 0x2,
    kIOHIDDigitizerEventPosition = 0x4,
    kIOHIDEventFieldDigitizerIsDisplayIntegrated = 0xB0006,
};

// IOKit function pointers (resolved at runtime via dlsym)
// Use IOHIDEventCreateDigitizerFingerEvent (13 params), NOT WithQuality (17 params).
static IOHIDEventRef (*_IOHIDEventCreateDigitizerEvent)(CFAllocatorRef, uint64_t, IOHIDEventType,
    uint32_t, uint32_t, uint32_t, IOHIDFloat, IOHIDFloat, IOHIDFloat, IOHIDFloat,
    IOHIDFloat, IOHIDFloat, BOOL, BOOL, int) = NULL;
static IOHIDEventRef (*_IOHIDEventCreateDigitizerFingerEvent)(CFAllocatorRef, uint64_t,
    uint32_t, uint32_t, uint32_t,
    IOHIDFloat, IOHIDFloat, IOHIDFloat,
    IOHIDFloat, IOHIDFloat, IOHIDFloat,
    BOOL, BOOL, int) = NULL;
static void (*_IOHIDEventAppendEvent)(IOHIDEventRef, IOHIDEventRef) = NULL;
static void (*_IOHIDEventSetIntegerValue)(IOHIDEventRef, IOHIDEventField, int) = NULL;
static void (*_IOHIDEventSetSenderID)(IOHIDEventRef, uint64_t) = NULL;
static void (*_IOHIDEventSetFloatValue)(IOHIDEventRef, IOHIDEventField, IOHIDFloat) = NULL;

static BOOL _ioHIDLoaded = NO;

// FIX 3: Incrementing finger identifier per touch sequence
static uint32_t _nextFingerEventId = 1;

// Additional IOHIDEvent field constants for radius
enum {
    kIOHIDEventFieldDigitizerMajorRadius = 0xB0014,
    kIOHIDEventFieldDigitizerMinorRadius = 0xB0015,
};

static void NerveLoadIOHID(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!handle) return;

        _IOHIDEventCreateDigitizerEvent = dlsym(handle, "IOHIDEventCreateDigitizerEvent");
        _IOHIDEventCreateDigitizerFingerEvent = dlsym(handle, "IOHIDEventCreateDigitizerFingerEvent");
        _IOHIDEventAppendEvent = dlsym(handle, "IOHIDEventAppendEvent");
        _IOHIDEventSetIntegerValue = dlsym(handle, "IOHIDEventSetIntegerValue");
        _IOHIDEventSetSenderID = dlsym(handle, "IOHIDEventSetSenderID");
        _IOHIDEventSetFloatValue = dlsym(handle, "IOHIDEventSetFloatValue");

        _ioHIDLoaded = (_IOHIDEventCreateDigitizerEvent != NULL
                       && _IOHIDEventCreateDigitizerFingerEvent != NULL
                       && _IOHIDEventAppendEvent != NULL);
    });
}

/// Create a real IOHIDEvent digitizer event with proper finger data.
/// Enters the pipeline before UIKit, so the system creates proper UITouch objects.
static IOHIDEventRef NerveCreateHIDEvent(CGPoint point, UITouchPhase phase, uint32_t fingerId) {
    NerveLoadIOHID();
    if (!_ioHIDLoaded) return NULL;

    uint64_t timestamp = mach_absolute_time();

    BOOL isRange = (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved || phase == UITouchPhaseStationary);
    BOOL isTouch = isRange;

    uint32_t eventMask;
    if (phase == UITouchPhaseMoved || phase == UITouchPhaseStationary) {
        eventMask = kIOHIDDigitizerEventPosition;
    } else {
        eventMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
    }

    // Create parent hand event (position 0,0 — position lives on the finger sub-event)
    IOHIDEventRef handEvent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timestamp, kIOHIDDigitizerTransducerTypeHand,
        0, 0, eventMask,
        0, 0, 0, 0,       // x=0, y=0, z=0 (hand has no position)
        0, 0,              // pressure=0, twist=0
        false, isTouch, 0  // isRange=false for hand, isTouch varies
    );
    if (!handEvent) return NULL;

    _IOHIDEventSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    // FIX 1: Use IOHIDEventCreateDigitizerFingerEvent (not WithQuality)
    // Parameters: allocator, timestamp, identifier, fingerIndex, eventMask,
    //             x, y, z, tipPressure, twist, majorRadius,
    //             isRange, isTouch, options
    IOHIDEventRef fingerEvent = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, timestamp,
        fingerId,          // identifier — unique per touch sequence
        2,                 // fingerIndex (rightIndex)
        eventMask,         // eventMask — was MISSING before, causing param shift
        point.x, point.y, 0,  // position in screen points
        0, 0,              // tipPressure, twist
        5.0,               // majorRadius
        isRange, isTouch,
        0                  // options
    );
    if (fingerEvent) {
        _IOHIDEventSetIntegerValue(fingerEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        // Set radius explicitly (standard value)
        if (_IOHIDEventSetFloatValue) {
            _IOHIDEventSetFloatValue(fingerEvent, kIOHIDEventFieldDigitizerMajorRadius, 5.0);
            _IOHIDEventSetFloatValue(fingerEvent, kIOHIDEventFieldDigitizerMinorRadius, 5.0);
        }
        _IOHIDEventAppendEvent(handEvent, fingerEvent);
        CFRelease(fingerEvent);
    }

    if (_IOHIDEventSetSenderID) {
        _IOHIDEventSetSenderID(handEvent, 0x0000000123456789);  // standard value
    }

    return handEvent;
}

// --- BackBoardServices (for HID event injection) ---

// BKSHIDEventSetDigitizerInfo stamps the IOHIDEvent with the window context ID,
// which routes the event to the correct window in the compositing system.
// FIX: Correct signature — last two params are CFTimeInterval (double) and float, not uint32_t
typedef void (*BKSHIDEventSetDigitizerInfoFunc)(IOHIDEventRef, uint32_t, uint8_t, uint8_t, CFStringRef, CFTimeInterval, float);
static BKSHIDEventSetDigitizerInfoFunc _BKSHIDEventSetDigitizerInfo = NULL;
static BOOL _bksLoaded = NO;

static void NerveLoadBackBoardServices(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_NOW);
        if (!handle) return;
        _BKSHIDEventSetDigitizerInfo = dlsym(handle, "BKSHIDEventSetDigitizerInfo");
        _bksLoaded = (_BKSHIDEventSetDigitizerInfo != NULL);
    });
}

/// Get the window's context ID (private property _contextId).
/// Returns 0 on device (which is fine — events still route correctly).
static uint32_t NerveGetWindowContextId(UIWindow *window) {
    Ivar ivar = class_getInstanceVariable(object_getClass(window), "_contextId");
    if (!ivar) return 0;
    ptrdiff_t offset = ivar_getOffset(ivar);
    uint32_t contextId = 0;
    memcpy(&contextId, (char *)(__bridge void *)window + offset, sizeof(uint32_t));
    return contextId;
}

// --- HID Event Injection ---

/// Send a finger event via _enqueueHIDEvent: — enters the pipeline before UIKit,
/// so the system creates proper UITouch objects and routes through SwiftUI gesture recognizers.
//// Enters the HID pipeline before UIKit processing.
static void NerveEnqueueFingerEvent(CGPoint point, UITouchPhase phase, UIWindow *window, uint32_t fingerId) {
    NerveLoadIOHID();
    NerveLoadBackBoardServices();
    if (!_ioHIDLoaded) return;

    IOHIDEventRef event = NerveCreateHIDEvent(point, phase, fingerId);
    if (!event) return;

    // Stamp with window context ID for correct routing
    if (_bksLoaded) {
        uint32_t contextId = 0;
        SEL contextIdSel = NSSelectorFromString(@"_contextId");
        if ([window respondsToSelector:contextIdSel]) {
            contextId = ((uint32_t(*)(id, SEL))objc_msgSend)(window, contextIdSel);
        }
        if (contextId == 0) {
            contextId = NerveGetWindowContextId(window);
        }
        _BKSHIDEventSetDigitizerInfo(event, contextId, false, false, NULL, 0.0, 0.0f);
    }

    // Enqueue via UIApplication._enqueueHIDEvent:
    UIApplication *app = [UIApplication sharedApplication];
    SEL enqueueSel = NSSelectorFromString(@"_enqueueHIDEvent:");
    if ([app respondsToSelector:enqueueSel]) {
        ((void(*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, enqueueSel, event);
    }

    CFRelease(event);
}

/// Find the topmost visible window at a given screen-space point.
UIWindow *_Nullable NerveFindWindowAtPoint(CGPoint screenPoint) {
    NSArray<UIWindow *> *allWindows = NerveGetAllWindows();
    for (NSInteger i = allWindows.count - 1; i >= 0; i--) {
        UIWindow *w = allWindows[i];
        if (w.isHidden || w.alpha < 0.01) continue;
        CGPoint wp = [w convertPoint:screenPoint fromWindow:nil];
        UIView *hit = [w hitTest:wp withEvent:nil];
        if (hit && hit != w) return w;
    }
    return allWindows.lastObject;
}

// --- Ivar helpers (kept for heap inspection) ---

static BOOL NerveSetIvar(id obj, const char *ivarName, const void *value, size_t size) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    memcpy((char *)(__bridge void *)obj + offset, value, size);
    return YES;
}

static BOOL NerveSetObjectIvar(id obj, const char *ivarName, id value) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!ivar) return NO;
    object_setIvar(obj, ivar, value);
    return YES;
}

static BOOL NerveGetIvar(id obj, const char *ivarName, void *outValue, size_t size) {
    Ivar ivar = class_getInstanceVariable(object_getClass(obj), ivarName);
    if (!ivar) return NO;
    ptrdiff_t offset = ivar_getOffset(ivar);
    memcpy(outValue, (char *)(__bridge void *)obj + offset, size);
    return YES;
}

// --- Public touch synthesis functions ---

BOOL NerveSynthesizeTap(CGPoint point, UIWindow *window) {
    if (!window) return NO;

    UIWindow *targetWindow = NerveFindWindowAtPoint(point);
    if (!targetWindow) targetWindow = window;

    // FIX 3: Use incrementing finger ID per tap
    uint32_t fingerId = _nextFingerEventId++;

    // Finger down
    NerveEnqueueFingerEvent(point, UITouchPhaseBegan, targetWindow, fingerId);

    // FIX 2: Spin the RunLoop between began and ended (standard value).
    // dispatch_after does NOT allow UIKit to process the touch-began before
    // touch-ended arrives. RunLoop spinning is essential.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];

    // Finger up
    NerveEnqueueFingerEvent(point, UITouchPhaseEnded, targetWindow, fingerId);

    return YES;
}

BOOL NerveSynthesizeLongPress(CGPoint point, NSTimeInterval duration, UIWindow *window) {
    if (!window) return NO;

    UIWindow *targetWindow = NerveFindWindowAtPoint(point);
    if (!targetWindow) targetWindow = window;

    uint32_t fingerId = _nextFingerEventId++;
    int steps = (int)(duration / 0.05);

    // Finger down
    NerveEnqueueFingerEvent(point, UITouchPhaseBegan, targetWindow, fingerId);

    // Hold: just spin the RunLoop for the full duration.
    // The gesture recognizer detects that the touch stays down without ending.
    // Stationary events are not needed — the began event starts the touch,
    // and the system considers it held as long as no ended event arrives.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:duration]];

    // Finger up
    NerveEnqueueFingerEvent(point, UITouchPhaseEnded, targetWindow, fingerId);

    return YES;
}

BOOL NerveSynthesizeDrag(NSArray<NSValue *> *points, NSTimeInterval duration, UIWindow *window) {
    if (!window || points.count < 2) return NO;

    CGPoint startPoint = points.firstObject.CGPointValue;
    UIWindow *targetWindow = NerveFindWindowAtPoint(startPoint);
    if (!targetWindow) targetWindow = window;

    uint32_t fingerId = _nextFingerEventId++;
    NSTimeInterval stepDuration = duration / (points.count - 1);

    // Finger down at start point
    NerveEnqueueFingerEvent(startPoint, UITouchPhaseBegan, targetWindow, fingerId);

    // Move through intermediate points with RunLoop spinning
    for (NSUInteger i = 1; i < points.count; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:stepDuration]];

        CGPoint pt = points[i].CGPointValue;
        BOOL isLast = (i == points.count - 1);

        if (isLast) {
            NerveEnqueueFingerEvent(pt, UITouchPhaseEnded, targetWindow, fingerId);
        } else {
            NerveEnqueueFingerEvent(pt, UITouchPhaseMoved, targetWindow, fingerId);
        }
    }

    return YES;
}

// MARK: - Double Tap

BOOL NerveSynthesizeDoubleTap(CGPoint point, UIWindow *window) {
    if (!window) return NO;

    UIWindow *targetWindow = NerveFindWindowAtPoint(point);
    if (!targetWindow) targetWindow = window;

    uint32_t fingerId = _nextFingerEventId++;

    // First tap
    NerveEnqueueFingerEvent(point, UITouchPhaseBegan, targetWindow, fingerId);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NerveEnqueueFingerEvent(point, UITouchPhaseEnded, targetWindow, fingerId);

    // Brief gap between taps (50ms)
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];

    // Second tap — same finger ID for double-tap recognition
    NerveEnqueueFingerEvent(point, UITouchPhaseBegan, targetWindow, fingerId);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NerveEnqueueFingerEvent(point, UITouchPhaseEnded, targetWindow, fingerId);

    return YES;
}

// MARK: - Drag and Drop

BOOL NerveSynthesizeDragDrop(CGPoint start, CGPoint end, NSTimeInterval holdDuration,
                              NSTimeInterval dragDuration, UIWindow *window) {
    if (!window) return NO;

    UIWindow *targetWindow = NerveFindWindowAtPoint(start);
    if (!targetWindow) targetWindow = window;

    uint32_t fingerId = _nextFingerEventId++;

    // Long press to pick up
    NerveEnqueueFingerEvent(start, UITouchPhaseBegan, targetWindow, fingerId);
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:holdDuration]];

    // Drag from start to end in steps
    int steps = 10;
    NSTimeInterval stepDuration = dragDuration / steps;
    for (int i = 1; i <= steps; i++) {
        CGFloat t = (CGFloat)i / steps;
        CGPoint pt = CGPointMake(
            start.x + (end.x - start.x) * t,
            start.y + (end.y - start.y) * t
        );
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:stepDuration]];
        NerveEnqueueFingerEvent(pt, UITouchPhaseMoved, targetWindow, fingerId);
    }

    // Release to drop
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    NerveEnqueueFingerEvent(end, UITouchPhaseEnded, targetWindow, fingerId);

    return YES;
}

// MARK: - Pinch / Zoom

/// Create an HID event with TWO finger children for multi-touch.
static IOHIDEventRef NerveCreateTwoFingerHIDEvent(CGPoint p1, CGPoint p2,
                                                    UITouchPhase phase,
                                                    uint32_t finger1Id,
                                                    uint32_t finger2Id) {
    NerveLoadIOHID();
    if (!_ioHIDLoaded) return NULL;

    uint64_t timestamp = mach_absolute_time();

    BOOL isRange = (phase == UITouchPhaseBegan || phase == UITouchPhaseMoved || phase == UITouchPhaseStationary);
    BOOL isTouch = isRange;

    uint32_t eventMask;
    if (phase == UITouchPhaseMoved) {
        eventMask = kIOHIDDigitizerEventPosition;
    } else {
        eventMask = kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch;
    }

    // Parent hand event
    IOHIDEventRef handEvent = _IOHIDEventCreateDigitizerEvent(
        kCFAllocatorDefault, timestamp, kIOHIDDigitizerTransducerTypeHand,
        0, 0, eventMask,
        0, 0, 0, 0,
        0, 0,
        false, isTouch, 0
    );
    if (!handEvent) return NULL;

    _IOHIDEventSetIntegerValue(handEvent, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);

    // Finger 1
    IOHIDEventRef finger1 = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, timestamp,
        finger1Id, 2, eventMask,
        p1.x, p1.y, 0,
        0, 0, 5.0,
        isRange, isTouch, 0
    );
    if (finger1) {
        _IOHIDEventSetIntegerValue(finger1, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        if (_IOHIDEventSetFloatValue) {
            _IOHIDEventSetFloatValue(finger1, kIOHIDEventFieldDigitizerMajorRadius, 5.0);
            _IOHIDEventSetFloatValue(finger1, kIOHIDEventFieldDigitizerMinorRadius, 5.0);
        }
        _IOHIDEventAppendEvent(handEvent, finger1);
        CFRelease(finger1);
    }

    // Finger 2
    IOHIDEventRef finger2 = _IOHIDEventCreateDigitizerFingerEvent(
        kCFAllocatorDefault, timestamp,
        finger2Id, 3, eventMask,  // fingerIndex=3 for second finger
        p2.x, p2.y, 0,
        0, 0, 5.0,
        isRange, isTouch, 0
    );
    if (finger2) {
        _IOHIDEventSetIntegerValue(finger2, kIOHIDEventFieldDigitizerIsDisplayIntegrated, 1);
        if (_IOHIDEventSetFloatValue) {
            _IOHIDEventSetFloatValue(finger2, kIOHIDEventFieldDigitizerMajorRadius, 5.0);
            _IOHIDEventSetFloatValue(finger2, kIOHIDEventFieldDigitizerMinorRadius, 5.0);
        }
        _IOHIDEventAppendEvent(handEvent, finger2);
        CFRelease(finger2);
    }

    if (_IOHIDEventSetSenderID) {
        _IOHIDEventSetSenderID(handEvent, 0x0000000123456789);
    }

    return handEvent;
}

/// Enqueue a two-finger HID event.
static void NerveEnqueueTwoFingerEvent(CGPoint p1, CGPoint p2, UITouchPhase phase,
                                        UIWindow *window,
                                        uint32_t finger1Id, uint32_t finger2Id) {
    NerveLoadBackBoardServices();
    IOHIDEventRef event = NerveCreateTwoFingerHIDEvent(p1, p2, phase, finger1Id, finger2Id);
    if (!event) return;

    if (_bksLoaded) {
        uint32_t contextId = 0;
        SEL contextIdSel = NSSelectorFromString(@"_contextId");
        if ([window respondsToSelector:contextIdSel]) {
            contextId = ((uint32_t(*)(id, SEL))objc_msgSend)(window, contextIdSel);
        }
        if (contextId == 0) contextId = NerveGetWindowContextId(window);
        _BKSHIDEventSetDigitizerInfo(event, contextId, false, false, NULL, 0.0, 0.0f);
    }

    UIApplication *app = [UIApplication sharedApplication];
    SEL enqueueSel = NSSelectorFromString(@"_enqueueHIDEvent:");
    if ([app respondsToSelector:enqueueSel]) {
        ((void(*)(id, SEL, IOHIDEventRef))objc_msgSend)(app, enqueueSel, event);
    }

    CFRelease(event);
}

BOOL NerveSynthesizePinch(CGPoint center, CGFloat startDistance, CGFloat endDistance,
                           NSTimeInterval duration, UIWindow *window) {
    if (!window) return NO;

    UIWindow *targetWindow = NerveFindWindowAtPoint(center);
    if (!targetWindow) targetWindow = window;

    uint32_t finger1Id = _nextFingerEventId++;
    uint32_t finger2Id = _nextFingerEventId++;

    int steps = 15;
    NSTimeInterval stepDuration = duration / steps;

    // Calculate start positions (fingers above and below center)
    CGFloat halfStart = startDistance / 2.0;
    CGPoint p1Start = CGPointMake(center.x, center.y - halfStart);
    CGPoint p2Start = CGPointMake(center.x, center.y + halfStart);

    // Fingers down
    NerveEnqueueTwoFingerEvent(p1Start, p2Start, UITouchPhaseBegan, targetWindow, finger1Id, finger2Id);

    // Animate fingers apart or together
    for (int i = 1; i <= steps; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:stepDuration]];

        CGFloat t = (CGFloat)i / steps;
        CGFloat currentDist = startDistance + (endDistance - startDistance) * t;
        CGFloat half = currentDist / 2.0;

        CGPoint p1 = CGPointMake(center.x, center.y - half);
        CGPoint p2 = CGPointMake(center.x, center.y + half);

        NerveEnqueueTwoFingerEvent(p1, p2, UITouchPhaseMoved, targetWindow, finger1Id, finger2Id);
    }

    // Fingers up
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    CGFloat halfEnd = endDistance / 2.0;
    CGPoint p1End = CGPointMake(center.x, center.y - halfEnd);
    CGPoint p2End = CGPointMake(center.x, center.y + halfEnd);
    NerveEnqueueTwoFingerEvent(p1End, p2End, UITouchPhaseEnded, targetWindow, finger1Id, finger2Id);

    return YES;
}

// MARK: - Heap Inspection

// arm64 non-pointer isa mask
extern uint64_t objc_debug_isa_class_mask __attribute__((weak_import));

static kern_return_t nerve_memory_reader(task_t task, vm_address_t address, vm_size_t size, void **data) {
    *data = (void *)address;
    return KERN_SUCCESS;
}

static BOOL NervePointerIsReadable(const void *ptr) {
    vm_address_t address = (vm_address_t)ptr;
    vm_size_t size = 0;
    vm_address_t regionAddress = address;
    mach_msg_type_number_t infoCount = VM_REGION_BASIC_INFO_COUNT_64;
    vm_region_basic_info_data_64_t info;
    mach_port_t objectName = MACH_PORT_NULL;

    kern_return_t kr = vm_region_64(
        mach_task_self(),
        &regionAddress,
        &size,
        VM_REGION_BASIC_INFO_64,
        (vm_region_info_t)&info,
        &infoCount,
        &objectName
    );

    if (kr != KERN_SUCCESS) return NO;
    if (regionAddress > address) return NO;
    if (!(info.protection & VM_PROT_READ)) return NO;

    return YES;
}

BOOL NervePointerIsValidObject(const void *ptr) {
    if (!ptr) return NO;

    // Check alignment
    if ((uintptr_t)ptr % sizeof(uintptr_t) != 0) return NO;

    // Check high bits (should not be set for valid heap pointers)
    if ((uintptr_t)ptr >> 55) return NO;

    // Check pointer is readable
    if (!NervePointerIsReadable(ptr)) return NO;

    // Read isa
    uintptr_t isaValue = *(uintptr_t *)ptr;

    // Mask isa on arm64
#if __arm64__
    if (&objc_debug_isa_class_mask) {
        isaValue &= objc_debug_isa_class_mask;
    }
#endif

    Class cls = (__bridge Class)(void *)isaValue;

    // Check if the isa is readable and is a valid class
    if (!NervePointerIsReadable((void *)isaValue)) return NO;
    if (!object_isClass(cls)) return NO;

    // Check malloc_size >= instance size
    size_t allocSize = malloc_size(ptr);
    if (allocSize < class_getInstanceSize(cls)) return NO;

    return YES;
}

// Heap scan statics — used by the C callback (safe: zone lock serializes access)
static Class _heapTargetClass = nil;
static NSMutableArray *_heapResults = nil;
static NSUInteger _heapLimit = 0;
static CFMutableSetRef _heapClassSet = NULL;

static void nerve_heap_range_callback(task_t task, void *context, unsigned type,
                                       vm_range_t *ranges, unsigned rangeCount) {
    if (!_heapResults || !_heapClassSet) return;

    for (unsigned i = 0; i < rangeCount; i++) {
        const void *ptr = (const void *)ranges[i].address;
        size_t size = ranges[i].size;

        if (size < sizeof(uintptr_t)) continue;
        if (_heapLimit > 0 && _heapResults.count >= _heapLimit) return;

        uintptr_t isaValue = *(uintptr_t *)ptr;

#if __arm64__
        if (&objc_debug_isa_class_mask) {
            isaValue &= objc_debug_isa_class_mask;
        }
#endif

        Class cls = (__bridge Class)(void *)isaValue;

        if (!CFSetContainsValue(_heapClassSet, (void *)isaValue)) continue;
        if (size < class_getInstanceSize(cls)) continue;

        // Check if this class is or inherits from the target
        Class walk = cls;
        while (walk) {
            if (walk == _heapTargetClass) {
                id obj = (__bridge id)(void *)ptr;
                [_heapResults addObject:obj];
                break;
            }
            walk = class_getSuperclass(walk);
        }
    }
}

NSArray *NerveHeapInstances(NSString *className, NSUInteger limit) {
    Class targetClass = NSClassFromString(className);
    if (!targetClass) return @[];

    // Build class set for isa validation
    unsigned int classCount = 0;
    Class *allClasses = objc_copyClassList(&classCount);
    _heapClassSet = CFSetCreateMutable(NULL, classCount, NULL);
    for (unsigned int i = 0; i < classCount; i++) {
        CFSetAddValue(_heapClassSet, (__bridge void *)allClasses[i]);
    }
    free(allClasses);

    _heapTargetClass = targetClass;
    _heapResults = [NSMutableArray new];
    _heapLimit = limit;

    vm_address_t *zones = NULL;
    unsigned int zoneCount = 0;
    kern_return_t kr = malloc_get_all_zones(TASK_NULL, nerve_memory_reader, &zones, &zoneCount);

    if (kr == KERN_SUCCESS) {
        for (unsigned int z = 0; z < zoneCount; z++) {
            malloc_zone_t *zone = (malloc_zone_t *)zones[z];
            if (!zone || !zone->introspect || !zone->introspect->enumerator) continue;

            if (zone->introspect->force_lock) {
                zone->introspect->force_lock(zone);
            }
            zone->introspect->enumerator(TASK_NULL, NULL,
                                          MALLOC_PTR_IN_USE_RANGE_TYPE,
                                          (vm_address_t)zone,
                                          nerve_memory_reader,
                                          nerve_heap_range_callback);
            if (zone->introspect->force_unlock) {
                zone->introspect->force_unlock(zone);
            }

            if (_heapLimit > 0 && _heapResults.count >= _heapLimit) break;
        }
    }

    NSArray *results = [_heapResults copy];
    _heapResults = nil;
    _heapTargetClass = nil;
    CFRelease(_heapClassSet);
    _heapClassSet = NULL;

    return results;
}

// MARK: - Network Interception

// Forward declare the Swift-side registration function
static BOOL _networkInterceptionActive = NO;

void NerveStartNetworkInterception(void) {
    if (_networkInterceptionActive) return;
    _networkInterceptionActive = YES;

    // Register protocol class globally — covers URLSession.shared
    Class nerveProtocolClass = NSClassFromString(@"Nerve.NerveURLProtocol");
    if (!nerveProtocolClass) nerveProtocolClass = NSClassFromString(@"NerveURLProtocol");
    if (nerveProtocolClass) {
        [NSURLProtocol registerClass:nerveProtocolClass];
    }

    // Swizzle URLSessionConfiguration.default and .ephemeral to inject our protocol
    Class configClass = [NSURLSessionConfiguration class];

    // Swizzle the class method 'defaultSessionConfiguration'
    SEL originalDefault = @selector(defaultSessionConfiguration);
    Method originalMethod = class_getClassMethod(configClass, originalDefault);
    if (!originalMethod) return;

    IMP originalIMP = method_getImplementation(originalMethod);

    IMP newIMP = imp_implementationWithBlock(^NSURLSessionConfiguration *(id self) {
        NSURLSessionConfiguration *config = ((NSURLSessionConfiguration *(*)(id, SEL))originalIMP)(self, originalDefault);
        // Inject our protocol class (registered from Swift side)
        Class nerveProtocol = NSClassFromString(@"Nerve.NerveURLProtocol");
        if (!nerveProtocol) nerveProtocol = NSClassFromString(@"NerveURLProtocol");
        if (nerveProtocol) {
            NSMutableArray *protocols = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
            if (![protocols containsObject:nerveProtocol]) {
                [protocols insertObject:nerveProtocol atIndex:0];
            }
            config.protocolClasses = protocols;
        }
        return config;
    });
    method_setImplementation(originalMethod, newIMP);

    // Same for ephemeral
    SEL originalEphemeral = @selector(ephemeralSessionConfiguration);
    Method ephemeralMethod = class_getClassMethod(configClass, originalEphemeral);
    if (ephemeralMethod) {
        IMP ephemeralIMP = method_getImplementation(ephemeralMethod);
        IMP newEphemeralIMP = imp_implementationWithBlock(^NSURLSessionConfiguration *(id self) {
            NSURLSessionConfiguration *config = ((NSURLSessionConfiguration *(*)(id, SEL))ephemeralIMP)(self, originalEphemeral);
            Class nerveProtocol = NSClassFromString(@"Nerve.NerveURLProtocol");
            if (!nerveProtocol) nerveProtocol = NSClassFromString(@"NerveURLProtocol");
            if (nerveProtocol) {
                NSMutableArray *protocols = [NSMutableArray arrayWithArray:config.protocolClasses ?: @[]];
                if (![protocols containsObject:nerveProtocol]) {
                    [protocols insertObject:nerveProtocol atIndex:0];
                }
                config.protocolClasses = protocols;
            }
            return config;
        });
        method_setImplementation(ephemeralMethod, newEphemeralIMP);
    }
}

void NerveStopNetworkInterception(void) {
    _networkInterceptionActive = NO;
    // Note: un-swizzling is generally unsafe. We just stop recording.
}

// MARK: - Accessibility

void NerveEnableAccessibility(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // Build the path to libAccessibility.dylib
        // On simulator, must use the IPHONE_SIMULATOR_ROOT-prefixed path
        NSDictionary *env = [[NSProcessInfo processInfo] environment];
        NSString *simulatorRoot = env[@"IPHONE_SIMULATOR_ROOT"];
        NSString *libPath = @"/usr/lib/libAccessibility.dylib";
        if (simulatorRoot) {
            libPath = [simulatorRoot stringByAppendingPathComponent:libPath];
        }

        void *handle = dlopen([libPath fileSystemRepresentation], RTLD_LOCAL);
        if (!handle) return;

        // _AXSSetAutomationEnabled activates the accessibility subsystem,
        // causing SwiftUI's _UIHostingView to populate its accessibilityElements.
        // This populates SwiftUI's accessibility elements.
        void (*_AXSSetAutomationEnabled)(int) = dlsym(handle, "_AXSSetAutomationEnabled");
        if (_AXSSetAutomationEnabled) {
            _AXSSetAutomationEnabled(YES);
        }

        // Post accessibility notifications after a short delay to trigger tree population.
        // This tells apps "VoiceOver status changed" so they populate labels,
        // without actually enabling VoiceOver (which would interfere with touch input).
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NervePostAccessibilityNotifications();
        });
    });
}

void NervePostAccessibilityNotifications(void) {
    // Post VoiceOver status change — apps listening for this will populate labels
    [[NSNotificationCenter defaultCenter]
        postNotificationName:UIAccessibilityVoiceOverStatusDidChangeNotification
        object:nil];

    // Post screen changed — forces SwiftUI to re-evaluate accessibility tree
    UIAccessibilityPostNotification(UIAccessibilityScreenChangedNotification, nil);

    // Post layout changed — triggers re-layout of accessibility elements
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification, nil);
}

// MARK: - Auto-Tagging (#10)

/// Sanitize a string for use as an accessibility identifier.
static NSString *NerveSanitizeIdentifier(NSString *text) {
    if (!text || text.length == 0) return nil;
    NSString *lower = [text lowercaseString];
    NSMutableString *sanitized = [NSMutableString new];
    for (NSUInteger i = 0; i < lower.length && i < 40; i++) {
        unichar c = [lower characterAtIndex:i];
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
            [sanitized appendFormat:@"%C", c];
        } else {
            if (sanitized.length > 0 && [sanitized characterAtIndex:sanitized.length - 1] != '_') {
                [sanitized appendString:@"_"];
            }
        }
    }
    // Trim trailing underscore
    while (sanitized.length > 0 && [sanitized characterAtIndex:sanitized.length - 1] == '_') {
        [sanitized deleteCharactersInRange:NSMakeRange(sanitized.length - 1, 1)];
    }
    return sanitized.length > 0 ? sanitized : nil;
}

static void NerveTagView(UIView *view, NSMutableDictionary<NSString *, NSNumber *> *counters) {
    // Skip if already has an identifier
    if (view.accessibilityIdentifier.length > 0) return;

    NSString *prefix = nil;
    NSString *text = nil;

    if ([view isKindOfClass:[UIButton class]]) {
        prefix = @"button";
        text = ((UIButton *)view).currentTitle;
    } else if ([view isKindOfClass:[UITextField class]]) {
        prefix = @"textfield";
        text = ((UITextField *)view).placeholder ?: ((UITextField *)view).accessibilityLabel;
    } else if ([view isKindOfClass:[UITextView class]]) {
        prefix = @"textview";
    } else if ([view isKindOfClass:[UISwitch class]]) {
        prefix = @"switch";
    } else if ([view isKindOfClass:[UISlider class]]) {
        prefix = @"slider";
    } else if ([view isKindOfClass:[UISegmentedControl class]]) {
        prefix = @"segment";
    } else if ([view isKindOfClass:[UISearchBar class]]) {
        prefix = @"searchbar";
    } else if ([view isKindOfClass:[UITableViewCell class]]) {
        prefix = @"cell";
        text = ((UITableViewCell *)view).textLabel.text;
    } else if ([view isKindOfClass:[UICollectionViewCell class]]) {
        prefix = @"cell";
        text = view.accessibilityLabel;
    } else if ([view isKindOfClass:[UILabel class]] && ((UILabel *)view).text.length > 0) {
        prefix = @"label";
        text = ((UILabel *)view).text;
    }

    if (!prefix) return;

    NSString *sanitized = text ? NerveSanitizeIdentifier(text) : nil;
    NSString *identifier;
    if (sanitized) {
        identifier = [NSString stringWithFormat:@"%@_%@", prefix, sanitized];
    } else {
        NSNumber *count = counters[prefix] ?: @0;
        identifier = [NSString stringWithFormat:@"%@_%@", prefix, count];
        counters[prefix] = @(count.integerValue + 1);
    }

    view.accessibilityIdentifier = identifier;
}

void NerveAutoTagElements(UIView *rootView) {
    if (!rootView) return;

    NSMutableDictionary<NSString *, NSNumber *> *counters = [NSMutableDictionary new];

    __block void (^walkBlock)(UIView *) = nil;
    walkBlock = ^(UIView *view) {
        NerveTagView(view, counters);
        for (UIView *subview in view.subviews) {
            walkBlock(subview);
        }
    };
    walkBlock(rootView);
}

// NerveInstallAutoTagging is now merged into the navigation viewDidAppear swizzle
// to avoid double-swizzling viewDidAppear: which causes infinite loops.
void NerveInstallAutoTagging(void) {
    // No-op: auto-tagging is handled by nerve_vc_didAppear in the navigation swizzle
}

// MARK: - Runtime Utilities

NSDictionary<NSString *, NSString *> *NerveListProperties(Class cls) {
    NSMutableDictionary *result = [NSMutableDictionary new];
    Class current = cls;
    while (current && current != [NSObject class]) {
        NSString *className = NSStringFromClass(current);
        // Stop walking up when we hit UIKit/Foundation base classes
        BOOL isSystemClass = [className hasPrefix:@"UI"] || [className hasPrefix:@"NS"]
            || [className hasPrefix:@"_UI"] || [className hasPrefix:@"_NS"]
            || [className hasPrefix:@"CA"] || [className hasPrefix:@"SwiftUI."];

        unsigned int count = 0;
        objc_property_t *props = class_copyPropertyList(current, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = [NSString stringWithUTF8String:property_getName(props[i])];
            // Skip private/internal properties on system classes
            if (isSystemClass && [name hasPrefix:@"_"]) continue;
            const char *attrs = property_getAttributes(props[i]);
            NSString *type = attrs ? [NSString stringWithUTF8String:attrs] : @"?";
            result[name] = type;
        }
        free(props);

        // For system classes, only include the directly requested class (don't walk up)
        if (isSystemClass) break;

        current = class_getSuperclass(current);
    }
    return result;
}

id NerveReadProperty(id object, NSString *keyPath) {
    if (!object || !keyPath) return nil;

    // Skip known crashy properties on UIKit classes
    static NSSet *unsafeProps = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        unsafeProps = [NSSet setWithArray:@[
            @"traitCollection", @"traitOverrides", @"focusGroupIdentifier",
            @"_viewDelegate", @"_contentView", @"_gestureInfo",
            @"recursiveDescription", @"_autolayoutTrace",
            @"_ivarDescription", @"_methodDescription"
        ]];
    });
    if ([unsafeProps containsObject:keyPath]) return @"<skipped>";

    @try {
        // Use valueForKey (not keyPath) to avoid traversing nested paths
        return [object valueForKey:keyPath];
    } @catch (NSException *e) {
        return nil;
    }
}

NSString *NerveClassName(id object) {
    if (!object) return @"nil";
    const char *name = class_getName(object_getClass(object));
    NSString *className = [NSString stringWithUTF8String:name];

    // Attempt Swift demangling
    // Swift class names look like "_TtC7ModuleName9ClassName" or "ModuleName.ClassName"
    if ([className containsString:@"."]) {
        // Already demangled (Module.Class format)
        return className;
    }

    // Try swift_demangle if available
    typedef char *(*swift_demangle_func)(const char *, size_t, char *, size_t *, uint32_t);
    static swift_demangle_func demangle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        demangle = (swift_demangle_func)dlsym(RTLD_DEFAULT, "swift_demangle");
    });

    if (demangle) {
        char *demangled = demangle(name, strlen(name), NULL, NULL, 0);
        if (demangled) {
            NSString *result = [NSString stringWithUTF8String:demangled];
            free(demangled);
            return result;
        }
    }

    return className;
}

BOOL NerveIsSwiftObject(id object) {
    if (!object) return NO;
    Class cls = object_getClass(object);

    // Check FAST_IS_SWIFT_STABLE bit (bit 1) in the class's internal bits field
    // Check FAST_IS_SWIFT_STABLE bit
    typedef struct {
        Class isa;
        Class superclass;
        void *cache1;
        void *cache2;
        uintptr_t bits;
    } objc_class_internals;

    objc_class_internals *classData = (__bridge void *)cls;
    return (classData->bits & 2) != 0; // FAST_IS_SWIFT_STABLE = 0x2
}

// MARK: - Navigation Observation

static NerveNavCallback _navCallback = NULL;

/// Helper: swizzle an instance method on a class.
static void NerveSwizzle(Class cls, SEL original, SEL swizzled) {
    Method origMethod = class_getInstanceMethod(cls, original);
    Method swizMethod = class_getInstanceMethod(cls, swizzled);
    if (!origMethod || !swizMethod) return;

    if (class_addMethod(cls, original, method_getImplementation(swizMethod), method_getTypeEncoding(swizMethod))) {
        class_replaceMethod(cls, swizzled, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
    } else {
        method_exchangeImplementations(origMethod, swizMethod);
    }
}

// --- Screen Name Resolution ---

/// Returns a human-readable screen name for a view controller.
/// Prefers: navigationItem.title > tabBarItem.title > title > class name.
static NSString *NerveScreenName(UIViewController *vc) {
    if (!vc) return @"(unknown)";

    // Try navigation title
    NSString *navTitle = vc.navigationItem.title;
    if (navTitle.length > 0) return navTitle;

    // Try VC title
    NSString *title = vc.title;
    if (title.length > 0) return title;

    // Try tab bar title
    NSString *tabTitle = vc.tabBarItem.title;
    if (tabTitle.length > 0) return tabTitle;

    // For navigation controllers, use the top VC's title
    if ([vc isKindOfClass:[UINavigationController class]]) {
        UIViewController *topVC = [(UINavigationController *)vc topViewController];
        if (topVC && topVC != vc) return NerveScreenName(topVC);
    }

    // For tab bar controllers, use the selected VC's title
    if ([vc isKindOfClass:[UITabBarController class]]) {
        UIViewController *selectedVC = [(UITabBarController *)vc selectedViewController];
        if (selectedVC && selectedVC != vc) return NerveScreenName(selectedVC);
    }

    // Fallback to class name, but clean up SwiftUI noise
    NSString *className = NerveClassName(vc);

    // Strip common SwiftUI wrapper prefixes for readability
    if ([className hasPrefix:@"SwiftUI."]) {
        // For hosting controllers, try to get the hosted view's title
        if ([className containsString:@"HostingController"] || [className containsString:@"NavigationStack"]) {
            // Check child VCs
            for (UIViewController *child in vc.childViewControllers) {
                NSString *childName = NerveScreenName(child);
                if (![childName hasPrefix:@"SwiftUI."] && ![childName isEqualToString:@"(unknown)"]) {
                    return childName;
                }
            }
        }
    }

    return className;
}

// --- UINavigationController.pushViewController:animated: ---

static void nerve_nav_push(id self, SEL _cmd, UIViewController *vc, BOOL animated) {
    // Get "from" before push
    UIViewController *fromVC = [(UINavigationController *)self topViewController];
    NSString *from = fromVC ? NerveScreenName(fromVC) : @"(root)";
    NSString *to = NerveScreenName(vc);

    // Call original
    SEL origSel = NSSelectorFromString(@"nerve_original_pushViewController:animated:");
    ((void(*)(id, SEL, UIViewController *, BOOL))objc_msgSend)(self, origSel, vc, animated);

    if (_navCallback) _navCallback(from, to, @"push");
}

// --- UIViewController.presentViewController:animated:completion: ---

static void nerve_vc_present(id self, SEL _cmd, UIViewController *vc, BOOL animated, void (^completion)(void)) {
    NSString *from = NerveScreenName((UIViewController *)self);
    NSString *to = NerveScreenName(vc);

    SEL origSel = NSSelectorFromString(@"nerve_original_presentViewController:animated:completion:");
    ((void(*)(id, SEL, UIViewController *, BOOL, void(^)(void)))objc_msgSend)(self, origSel, vc, animated, completion);

    if (_navCallback) _navCallback(from, to, @"present");
}

// --- UITabBarController.setSelectedIndex: ---

static void nerve_tab_setIndex(id self, SEL _cmd, NSUInteger index) {
    UITabBarController *tab = (UITabBarController *)self;
    UIViewController *fromVC = tab.selectedViewController;
    NSString *from = fromVC ? NerveScreenName(fromVC) : @"(none)";

    SEL origSel = NSSelectorFromString(@"nerve_original_setSelectedIndex:");
    ((void(*)(id, SEL, NSUInteger))objc_msgSend)(self, origSel, index);

    UIViewController *toVC = tab.selectedViewController;
    NSString *to = toVC ? NerveScreenName(toVC) : @"(none)";

    if (_navCallback && ![from isEqualToString:to]) {
        _navCallback(from, to, @"tab");
    }
}

// --- UIViewController.viewDidAppear: ---

static void nerve_vc_didAppear(id self, SEL _cmd, BOOL animated) {
    SEL origSel = NSSelectorFromString(@"nerve_original_viewDidAppear:");
    ((void(*)(id, SEL, BOOL))objc_msgSend)(self, origSel, animated);

    // Notify navigation observer
    if (_navCallback) {
        NSString *to = NerveScreenName((UIViewController *)self);
        _navCallback(@"", to, @"appear");
    }

    // Auto-tag disabled for now
    // UIViewController *vc = (UIViewController *)self;
    // if ([vc isKindOfClass:[UIViewController class]] && vc.view) {
    //     dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    //         NerveAutoTagElements(vc.view);
    //     });
    // }
}

void NerveInstallNavigationSwizzles(NerveNavCallback callback) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _navCallback = callback;

        // Swizzle UINavigationController.pushViewController:animated:
        {
            Class cls = [UINavigationController class];
            SEL orig = @selector(pushViewController:animated:);
            SEL swiz = NSSelectorFromString(@"nerve_original_pushViewController:animated:");
            // Add the original as a new selector, then replace the original with our impl
            Method origMethod = class_getInstanceMethod(cls, orig);
            class_addMethod(cls, swiz, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
            method_setImplementation(origMethod, (IMP)nerve_nav_push);
        }

        // Swizzle UIViewController.presentViewController:animated:completion:
        {
            Class cls = [UIViewController class];
            SEL orig = @selector(presentViewController:animated:completion:);
            SEL swiz = NSSelectorFromString(@"nerve_original_presentViewController:animated:completion:");
            Method origMethod = class_getInstanceMethod(cls, orig);
            class_addMethod(cls, swiz, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
            method_setImplementation(origMethod, (IMP)nerve_vc_present);
        }

        // Swizzle UITabBarController.setSelectedIndex:
        {
            Class cls = [UITabBarController class];
            SEL orig = @selector(setSelectedIndex:);
            SEL swiz = NSSelectorFromString(@"nerve_original_setSelectedIndex:");
            Method origMethod = class_getInstanceMethod(cls, orig);
            if (origMethod) {
                class_addMethod(cls, swiz, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
                method_setImplementation(origMethod, (IMP)nerve_tab_setIndex);
            }
        }

        // Swizzle UIViewController.viewDidAppear:
        {
            Class cls = [UIViewController class];
            SEL orig = @selector(viewDidAppear:);
            SEL swiz = NSSelectorFromString(@"nerve_original_viewDidAppear:");
            Method origMethod = class_getInstanceMethod(cls, orig);
            class_addMethod(cls, swiz, method_getImplementation(origMethod), method_getTypeEncoding(origMethod));
            method_setImplementation(origMethod, (IMP)nerve_vc_didAppear);
        }
    });
}

// MARK: - Bootstrap

// MARK: - Method Tracing

// Store original IMPs so we can remove traces
static NSMutableDictionary<NSString *, NSValue *> *_traceOriginalIMPs = nil;
static NerveTraceCallback _traceCallback = NULL;

BOOL NerveInstallTrace(NSString *className, NSString *methodName, BOOL isClassMethod,
                       NerveTraceCallback callback) {
    if (!_traceOriginalIMPs) {
        _traceOriginalIMPs = [NSMutableDictionary new];
    }
    _traceCallback = callback;

    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    SEL sel = NSSelectorFromString(methodName);
    Method method = isClassMethod
        ? class_getClassMethod(cls, sel)
        : class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    NSString *key = [NSString stringWithFormat:@"%@%@.%@", isClassMethod ? @"+" : @"-", className, methodName];

    // Already traced
    if (_traceOriginalIMPs[key]) return YES;

    IMP originalIMP = method_getImplementation(method);
    _traceOriginalIMPs[key] = [NSValue valueWithPointer:originalIMP];

    // Get method signature to determine argument count
    const char *typeEncoding = method_getTypeEncoding(method);
    unsigned int argCount = method_getNumberOfArguments(method) - 2; // subtract self, _cmd

    IMP newIMP = imp_implementationWithBlock(^(id self_arg, ...) {
        // Build args description
        NSMutableString *argsDesc = [NSMutableString new];
        if (argCount > 0) {
            // We can't reliably iterate va_args for ObjC objects,
            // so just report the arg count
            [argsDesc appendFormat:@"(%u args)", argCount];
        }

        NSString *actualClass = NSStringFromClass([self_arg class]);
        if (_traceCallback) {
            _traceCallback(actualClass, methodName, argsDesc);
        }

        // Call original — we use a simple void return forwarding
        // This works for void methods. For methods with return values,
        // we'd need more complex forwarding, but tracing is primarily
        // for observation, and most traced methods (viewDidAppear:, etc.) return void.
        ((void (*)(id, SEL))originalIMP)(self_arg, sel);
    });

    method_setImplementation(method, newIMP);
    return YES;
}

BOOL NerveRemoveTrace(NSString *className, NSString *methodName, BOOL isClassMethod) {
    NSString *key = [NSString stringWithFormat:@"%@%@.%@", isClassMethod ? @"+" : @"-", className, methodName];
    NSValue *originalValue = _traceOriginalIMPs[key];
    if (!originalValue) return NO;

    Class cls = NSClassFromString(className);
    if (!cls) return NO;

    SEL sel = NSSelectorFromString(methodName);
    Method method = isClassMethod
        ? class_getClassMethod(cls, sel)
        : class_getInstanceMethod(cls, sel);
    if (!method) return NO;

    IMP originalIMP = [originalValue pointerValue];
    method_setImplementation(method, originalIMP);
    [_traceOriginalIMPs removeObjectForKey:key];
    return YES;
}

void NerveRemoveAllTraces(void) {
    for (NSString *key in [_traceOriginalIMPs allKeys]) {
        // Parse key: "+ClassName.methodName" or "-ClassName.methodName"
        BOOL isClassMethod = [key hasPrefix:@"+"];
        NSString *rest = [key substringFromIndex:1];
        NSRange dotRange = [rest rangeOfString:@"."];
        if (dotRange.location == NSNotFound) continue;

        NSString *className = [rest substringToIndex:dotRange.location];
        NSString *methodName = [rest substringFromIndex:dotRange.location + 1];
        NerveRemoveTrace(className, methodName, isClassMethod);
    }
}

NSUInteger NerveActiveTraceCount(void) {
    return _traceOriginalIMPs.count;
}

// MARK: - Bootstrap

static void nerve_call_auto_start(void) {
    typedef void (*NerveStartFunc)(void);
    NerveStartFunc startFunc = (NerveStartFunc)dlsym(RTLD_DEFAULT, "nerve_auto_start");
    if (startFunc) {
        startFunc();
    }
}

void nerve_framework_init(void) {
    // This is called from __attribute__((constructor)) in NerveBootstrap.c
    // Register observer synchronously — must happen before the notification fires
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                      object:nil
                                                       queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(NSNotification *note) {
        nerve_call_auto_start();
    }];

    // If app already launched (e.g., dylib injected after launch), start immediately
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([UIApplication sharedApplication] != nil) {
            nerve_call_auto_start();
        }
    });
}

// MARK: - Debug: Swizzle UIApplication sendEvent to confirm touch delivery

static IMP _originalSendEvent = NULL;
static BOOL _nerveSendEventLogging = NO;

static void nerve_sendEvent(id self, SEL _cmd, UIEvent *event) {
    if (_nerveSendEventLogging && event.type == UIEventTypeTouches) {
        NSSet *touches = [event allTouches];
        for (UITouch *touch in touches) {
            CGPoint loc = [touch locationInView:touch.window];
            // Check private properties that might distinguish synthetic touches
            NSNumber *isTap = [touch respondsToSelector:NSSelectorFromString(@"_isTapTouch")]
                ? [touch valueForKey:@"_isTapTouch"] : nil;
            NSNumber *pressure = @(touch.force);
            NSNumber *touchType = @(touch.type);
            NSLog(@"[Nerve][sendEvent] phase=%ld point=(%.0f,%.0f) view=%@ type=%@ force=%.2f _isTapTouch=%@ tapCount=%ld gestureRecognizers=%lu",
                  (long)touch.phase, loc.x, loc.y,
                  touch.view ? NSStringFromClass([touch.view class]) : @"nil",
                  touchType, touch.force,
                  isTap ?: @"N/A",
                  (long)touch.tapCount,
                  (unsigned long)touch.gestureRecognizers.count);
        }
    }
    ((void(*)(id, SEL, UIEvent *))_originalSendEvent)(self, _cmd, event);
}

void NerveInstallSendEventLogging(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        Method m = class_getInstanceMethod([UIApplication class], @selector(sendEvent:));
        _originalSendEvent = method_getImplementation(m);
        method_setImplementation(m, (IMP)nerve_sendEvent);
        _nerveSendEventLogging = YES;
        NSLog(@"[Nerve] sendEvent logging installed");
    });
}

void NerveEnableSendEventLogging(BOOL enabled) {
    _nerveSendEventLogging = enabled;
}

#endif
