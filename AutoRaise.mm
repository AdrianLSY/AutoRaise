/*
 * AutoRaise - Copyright (C) 2026 sbmpost
 * Some pieces of the code are based on
 * metamove by jmgao as part of XFree86
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation; either version 2 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along
 * with this program; if not, write to the Free Software Foundation, Inc.,
 * 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
 */

// g++ -O2 -Wall -fobjc-arc -D"NS_FORMAT_ARGUMENT(A)=" -o AutoRaise AutoRaise.mm \
//   -framework AppKit && ./AutoRaise

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <Foundation/Foundation.h>
#include <AppKit/AppKit.h>
#include <Carbon/Carbon.h>
#include <libproc.h>

#define AUTORAISE_VERSION "6.0"
#define STACK_THRESHOLD 20

// It seems OSX Monterey introduced a transparent 3 pixel border around each window. This
// means that when two windows are visually precisely connected and not overlapping, in
// reality they are. Consequently one has to move the mouse 3 pixels further out of the
// visual area to make the connected window raise. This new OSX 'feature' also introduces
// unwanted raising of windows when visually connected to the top menu bar. To solve this
// we correct the mouse position before determining which window is underneath the mouse.
#define WINDOW_CORRECTION 3
#define MENUBAR_CORRECTION 8
#define SCREEN_EDGE_CORRECTION 1 // 1 <= value <= WINDOW_CORRECTION

// An activate delay of about 10 microseconds is just high enough to ensure we always
// find the latest focused (main)window. This value should be kept as low as possible.
#define ACTIVATE_DELAY_MS 10

#define SCALE_DELAY_MS 400 // The moment the mouse scaling should start, feel free to modify.
#define SCALE_DURATION_MS (SCALE_DELAY_MS+600) // Mouse scale duration, feel free to modify.
#define TASK_SWITCHER_MODIFIER_KEY kCGEventFlagMaskCommand // kCGEventFlagMaskControl, ...

// Raise retry schedule. These intervals cover app response time (Finder, Electron),
// not polling cadence — decoupled from pollMillis.
#define RAISE_RETRY_1_MS 50
#define RAISE_RETRY_2_MS 100

// Suppression window opened after app activation (cmd-tab, cmd-grave, etc.) during
// which incidental mouse-moved events do not trigger raises. Covers the warp +
// stabilization window before the new app's window is settled under the cursor.
#define SUPPRESS_MS 150

typedef int CGSConnectionID;
extern "C" CGSConnectionID CGSMainConnectionID(void);
extern "C" CGError CGSSetCursorScale(CGSConnectionID connectionId, float scale);
extern "C" CGError CGSGetCursorScale(CGSConnectionID connectionId, float *scale);
extern "C" AXError _AXUIElementGetWindow(AXUIElementRef, CGWindowID *out);
// Above methods are undocumented and subjective to incompatible changes

static AXObserverRef axObserver = NULL;
static uint64_t lastDestroyedMouseWindow_id = kCGNullWindowID;

static CFMachPortRef eventTap = NULL;
static char pathBuffer[PROC_PIDPATHINFO_MAXSIZE];
static bool activated_by_task_switcher = false;
static AXUIElementRef _accessibility_object = AXUIElementCreateSystemWide();
static AXUIElementRef _previousFinderWindow = NULL;
static AXUIElementRef _dock_app = NULL;
static NSArray * ignoreApps = NULL;
static NSArray * ignoreTitles = NULL;
static NSArray * stayFocusedBundleIds = NULL;
static NSArray * const mainWindowAppsWithoutTitle =@[
    @"System Settings",
    @"System Information",
    @"Photos",
    @"Calculator",
    @"Podcasts",
    @"Stickies Pro",
    @"Reeder"
];
static NSArray * pwas = @[
    @"Chrome",
    @"Chromium",
    @"Vivaldi",
    @"Brave",
    @"Opera",
    @"edgemac",
    @"helium"
];
static NSString * const DockBundleId = @"com.apple.dock";
static NSString * const FinderBundleId = @"com.apple.finder";
static NSString * const LittleSnitchBundleId = @"at.obdev.littlesnitch";
static NSString * const AssistiveControl = @"AssistiveControl";
static NSString * const MissionControl = @"Mission Control";
static NSString * const BartenderBar = @"Bartender Bar";
static NSString * const AppStoreSearchResults = @"Search results";
static NSString * const Untitled = @"Untitled"; // OSX Email search
static NSString * const Zim = @"Zim";
static NSString * const XQuartz = @"XQuartz";
static NSString * const Finder = @"Finder";
static NSString * const Pake = @"pake";
static NSString * const NoTitle = @"";
static CGPoint desktopOrigin = {0, 0};
static CGPoint oldPoint = {0, 0};
static bool ignoreSpaceChanged = false;
static bool invertDisableKey = false;
static bool invertIgnoreApps = false;
static bool altTaskSwitcher = false;
static bool warpMouse = false;
static bool verbose = false;
static float warpX = 0.5;
static float warpY = 0.5;
static float oldScale = 1;
static float cursorScale = 2;
static int pollMillis = 0;
static int disableKey = 0;

// Event-driven throttle + suppression state. All times in milliseconds since process
// start, using a monotonic clock. `raiseGeneration` is incremented every time a raise
// is issued; scheduled retries capture the generation at schedule time and only fire
// if it still matches at execution time.
static double lastCheckTime = 0;
static double suppressRaisesUntil = 0;
static uint64_t raiseGeneration = 0;

static inline double currentTimeMillis() {
    return [[NSProcessInfo processInfo] systemUptime] * 1000.0;
}

//---------------------------------------------helper methods-----------------------------------------------

inline void activate(pid_t pid) {
    if (verbose) { NSLog(@"Activate"); }
#ifdef OLD_ACTIVATION_METHOD
    ProcessSerialNumber process;
    OSStatus error = GetProcessForPID(pid, &process);
    if (!error) { SetFrontProcessWithOptions(&process, kSetFrontProcessFrontWindowOnly); }
#else
    // Note activateWithOptions does not work properly on OSX 11.1
    [[NSRunningApplication runningApplicationWithProcessIdentifier: pid]
        activateWithOptions: 0];
#endif
}

inline void raiseAndActivate(AXUIElementRef _window, pid_t window_pid) {
    if (verbose) { NSLog(@"Raise"); }
    if (AXUIElementPerformAction(_window, kAXRaiseAction) == kAXErrorSuccess) {
        activate(window_pid);
    }
}

inline void logWindowTitle(NSString * prefix, AXUIElementRef _window) {
    CFStringRef _windowTitle = NULL;
    AXUIElementCopyAttributeValue(_window, kAXTitleAttribute, (CFTypeRef *) &_windowTitle);
    if (_windowTitle) {
        NSLog(@"%@: `%@`", prefix, _windowTitle);
        CFRelease(_windowTitle);
    } else {
        pid_t pid;
        NSString * _appName = NULL;
        if (AXUIElementGetPid(_window, &pid) == kAXErrorSuccess) {
            _appName = [NSRunningApplication runningApplicationWithProcessIdentifier: pid].localizedName;
        }
        if (_appName) { NSLog(@"%@ (app name): `%@`", prefix, _appName); }
        else { NSLog(@"%@: null", prefix); }
    }
}

// TODO: does not take into account different languages
inline bool titleEquals(AXUIElementRef _element, NSArray * _titles, NSArray * _patterns = NULL, bool logTitle = false) {
    bool equal = false;
    CFStringRef _elementTitle = NULL;
    AXUIElementCopyAttributeValue(_element, kAXTitleAttribute, (CFTypeRef *) &_elementTitle);
    if (logTitle) { NSLog(@"element title: `%@`", _elementTitle); }
    if (_elementTitle) {
        NSString * _title = (__bridge NSString *) _elementTitle;
        equal = [_titles containsObject: _title];
        if (!equal && _patterns) {
            for (NSString * _pattern in _patterns) {
                equal = [_title rangeOfString: _pattern options: NSRegularExpressionSearch].location != NSNotFound;
                if (equal) { break; }
            }
        }
        CFRelease(_elementTitle);
    } else { equal = [_titles containsObject: NoTitle]; }
    return equal;
}

inline bool dock_active() {
    bool active = false;
    AXUIElementRef _focusedUIElement = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXFocusedUIElementAttribute, (CFTypeRef *) &_focusedUIElement);
    if (_focusedUIElement) {
        active = true;
        if (verbose) { NSLog(@"Dock is active"); }
        CFRelease(_focusedUIElement);
    }
    return active;
}

inline bool mc_active() {
    bool active = false;
    CFArrayRef _children = NULL;
    AXUIElementCopyAttributeValue(_dock_app, kAXChildrenAttribute, (CFTypeRef *) &_children);
    if (_children) {
        CFIndex count = CFArrayGetCount(_children);
        for (CFIndex i=0;!active && i != count;i++) {
            CFStringRef _element_role = NULL;
            AXUIElementRef _element = (AXUIElementRef) CFArrayGetValueAtIndex(_children, i);
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            if (_element_role) {
                active = CFEqual(_element_role, kAXGroupRole) && titleEquals(_element, @[MissionControl]);
                CFRelease(_element_role);
            }
        }
        CFRelease(_children);
    }

    if (verbose && active) { NSLog(@"Mission Control is active"); }
    return active;
}

NSDictionary * topwindow(CGPoint point) {
    NSDictionary * top_window = NULL;
    NSArray * window_list = (NSArray *) CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        kCGNullWindowID));

    for (NSDictionary * window in window_list) {
        NSDictionary * window_bounds_dict = window[(NSString *) CFBridgingRelease(kCGWindowBounds)];

        if (![window[(__bridge id) kCGWindowLayer] isEqual: @0]) { continue; }

        NSRect window_bounds = NSMakeRect(
            [window_bounds_dict[@"X"] intValue],
            [window_bounds_dict[@"Y"] intValue],
            [window_bounds_dict[@"Width"] intValue],
            [window_bounds_dict[@"Height"] intValue]);

        if (NSPointInRect(NSPointFromCGPoint(point), window_bounds)) {
            top_window = window;
            break;
        }
    }

    return top_window;
}

AXUIElementRef fallback(CGPoint point) {
    if (verbose) { NSLog(@"Fallback"); }
    AXUIElementRef _window = NULL;
    NSDictionary * top_window = topwindow(point);
    if (top_window) {
        CFTypeRef _windows_cf = NULL;
        pid_t pid = [top_window[(__bridge id) kCGWindowOwnerPID] intValue];
        AXUIElementRef _window_owner = AXUIElementCreateApplication(pid);
        AXUIElementCopyAttributeValue(_window_owner, kAXWindowsAttribute, &_windows_cf);
        CFRelease(_window_owner);
        if (_windows_cf) {
            NSArray * application_windows = (NSArray *) CFBridgingRelease(_windows_cf);
            CGWindowID top_window_id = [top_window[(__bridge id) kCGWindowNumber] intValue];
            if (top_window_id) {
                for (id application_window in application_windows) {
                    CGWindowID application_window_id;
                    AXUIElementRef application_window_ax =
                        (__bridge AXUIElementRef) application_window;
                    if (_AXUIElementGetWindow(
                        application_window_ax,
                        &application_window_id) == kAXErrorSuccess) {
                        if (application_window_id == top_window_id) {
                            _window = application_window_ax;
                            CFRetain(_window);
                            break;
                        }
                    }
                }
            }
        } else {
            activate(pid);
        }
    }

    return _window;
}

AXUIElementRef get_raisable_window(AXUIElementRef _element, CGPoint point, int count) {
    AXUIElementRef _window = NULL;
    if (_element) {
        if (count >= STACK_THRESHOLD) {
            if (verbose) {
                NSLog(@"Stack threshold reached");
                pid_t application_pid;
                if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                    proc_pidpath(application_pid, pathBuffer, sizeof(pathBuffer));
                    NSLog(@"Application path: %s", pathBuffer);
                }
            }
            CFRelease(_element);
        } else {
            CFStringRef _element_role = NULL;
            AXUIElementCopyAttributeValue(_element, kAXRoleAttribute, (CFTypeRef *) &_element_role);
            bool check_attributes = !_element_role;
            if (_element_role) {
                if (CFEqual(_element_role, kAXDockItemRole) ||
                    CFEqual(_element_role, kAXMenuItemRole) ||
                    CFEqual(_element_role, kAXMenuRole) ||
                    CFEqual(_element_role, kAXMenuBarRole) ||
                    CFEqual(_element_role, kAXMenuBarItemRole)) {
                    CFRelease(_element_role);
                    CFRelease(_element);
                } else if (
                    CFEqual(_element_role, kAXWindowRole) ||
                    CFEqual(_element_role, kAXSheetRole) ||
                    CFEqual(_element_role, kAXDrawerRole)) {
                    CFRelease(_element_role);
                    _window = _element;
                } else if (CFEqual(_element_role, kAXApplicationRole)) {
                    CFRelease(_element_role);
                    if (titleEquals(_element, @[XQuartz])) {
                        pid_t application_pid;
                        if (AXUIElementGetPid(_element, &application_pid) == kAXErrorSuccess) {
                            pid_t frontmost_pid = [[[NSWorkspace sharedWorkspace]
                                frontmostApplication] processIdentifier];
                            if (application_pid != frontmost_pid) {
                                // Focus and/or raising is the responsibility of XQuartz.
                                // As such AutoRaise features (delay/warp) do not apply.
                                activate(application_pid);
                            }
                        }
                        CFRelease(_element);
                    } else { check_attributes = true; }
                } else {
                    CFRelease(_element_role);
                    check_attributes = true;
                }
            }

            if (check_attributes) {
                AXUIElementCopyAttributeValue(_element, kAXParentAttribute, (CFTypeRef *) &_window);
                bool no_parent = !_window;
                _window = get_raisable_window(_window, point, ++count);
                if (!_window) {
                    AXUIElementCopyAttributeValue(_element, kAXWindowAttribute, (CFTypeRef *) &_window);
                    if (!_window && no_parent) { _window = fallback(point); }
                }
                CFRelease(_element);
            }
        }
    }

    return _window;
}

AXUIElementRef get_mousewindow(CGPoint point) {
    AXUIElementRef _element = NULL;
    AXError error = AXUIElementCopyElementAtPosition(_accessibility_object, point.x, point.y, &_element);

    AXUIElementRef _window = NULL;
    if (_element) {
        _window = get_raisable_window(_element, point, 0);
    } else if (error == kAXErrorCannotComplete || error == kAXErrorNotImplemented) {
        // fallback, happens for apps that do not support the Accessibility API
        if (verbose) { NSLog(@"Copy element: no accessibility support"); }
        _window = fallback(point);
    } else if (error == kAXErrorIllegalArgument) {
        // fallback, happens for Progressive Web Apps (PWAs)
        if (verbose) { NSLog(@"Copy element: illegal argument"); }
        _window = fallback(point);
    } else if (error == kAXErrorNoValue) {
        // fallback, happens sometimes when switching to another app (with cmd-tab)
        if (verbose) { NSLog(@"Copy element: no value"); }
        _window = fallback(point);
    } else if (error == kAXErrorAttributeUnsupported) {
        // no fallback, happens when hovering into volume/WiFi menubar window
        if (verbose) { NSLog(@"Copy element: attribute unsupported"); }
    } else if (error == kAXErrorFailure) {
        // no fallback, happens when hovering over the menubar itself
        if (verbose) { NSLog(@"Copy element: failure"); }
    } else if (verbose) {
        NSLog(@"Copy element: AXError %d", error);
    }

    if (verbose) {
        if (_window) { logWindowTitle(@"Mouse window", _window); }
        else { NSLog(@"No raisable window"); }
    }

    return _window;
}

CGPoint get_mousepoint(AXUIElementRef _window) {
    CGPoint mousepoint = {0, 0};
    AXValueRef _size = NULL;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
    if (_size) {
        AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
        if (_pos) {
            CGSize cg_size;
            CGPoint cg_pos;
            if (AXValueGetValue(_size, kAXValueTypeCGSize, &cg_size) &&
                AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos)) {
                mousepoint.x = cg_pos.x + (cg_size.width * warpX);
                mousepoint.y = cg_pos.y + (cg_size.height * warpY);
            }
            CFRelease(_pos);
        }
        CFRelease(_size);
    }

    return mousepoint;
}

bool contained_within(AXUIElementRef _window1, AXUIElementRef _window2) {
    bool contained = false;
    AXValueRef _size1 = NULL;
    AXValueRef _size2 = NULL;
    AXValueRef _pos1 = NULL;
    AXValueRef _pos2 = NULL;

    AXUIElementCopyAttributeValue(_window1, kAXSizeAttribute, (CFTypeRef *) &_size1);
    if (_size1) {
        AXUIElementCopyAttributeValue(_window1, kAXPositionAttribute, (CFTypeRef *) &_pos1);
        if (_pos1) {
            AXUIElementCopyAttributeValue(_window2, kAXSizeAttribute, (CFTypeRef *) &_size2);
            if (_size2) {
                AXUIElementCopyAttributeValue(_window2, kAXPositionAttribute, (CFTypeRef *) &_pos2);
                if (_pos2) {
                    CGSize cg_size1;
                    CGSize cg_size2;
                    CGPoint cg_pos1;
                    CGPoint cg_pos2;
                    if (AXValueGetValue(_size1, kAXValueTypeCGSize, &cg_size1) &&
                        AXValueGetValue(_pos1, kAXValueTypeCGPoint, &cg_pos1) &&
                        AXValueGetValue(_size2, kAXValueTypeCGSize, &cg_size2) &&
                        AXValueGetValue(_pos2, kAXValueTypeCGPoint, &cg_pos2)) {
                        contained = cg_pos1.x > cg_pos2.x && cg_pos1.y > cg_pos2.y &&
                            cg_pos1.x + cg_size1.width < cg_pos2.x + cg_size2.width &&
                            cg_pos1.y + cg_size1.height < cg_pos2.y + cg_size2.height;
                    }
                    CFRelease(_pos2);
                }
                CFRelease(_size2);
            }
            CFRelease(_pos1);
        }
        CFRelease(_size1);
    }

    return contained;
}

void findDockApplication() {
    NSArray * _apps = [[NSWorkspace sharedWorkspace] runningApplications];
    for (NSRunningApplication * app in _apps) {
        if ([app.bundleIdentifier isEqual: DockBundleId]) {
            _dock_app = AXUIElementCreateApplication(app.processIdentifier);
            break;
        }
    }

    if (verbose && !_dock_app) { NSLog(@"Dock application isn't running"); }
}

void findDesktopOrigin() {
    NSScreen * main_screen = NSScreen.screens[0];
    float mainScreenTop = NSMaxY(main_screen.frame);
    for (NSScreen * screen in [NSScreen screens]) {
        float screenOriginY = mainScreenTop - NSMaxY(screen.frame);
        if (screenOriginY < desktopOrigin.y) { desktopOrigin.y = screenOriginY; }
        if (screen.frame.origin.x < desktopOrigin.x) { desktopOrigin.x = screen.frame.origin.x; }
    }

    if (verbose) { NSLog(@"Desktop origin (%f, %f)", desktopOrigin.x, desktopOrigin.y); }
}

inline NSScreen * findScreen(CGPoint point) {
    NSScreen * main_screen = NSScreen.screens[0];
    point.y = NSMaxY(main_screen.frame) - point.y;
    for (NSScreen * screen in [NSScreen screens]) {
        NSRect screen_bounds = NSMakeRect(
            screen.frame.origin.x,
            screen.frame.origin.y,
            NSWidth(screen.frame) + 1,
            NSHeight(screen.frame) + 1
        );
        if (NSPointInRect(NSPointFromCGPoint(point), screen_bounds)) {
            return screen;
        }
    }
    return NULL;
}

inline bool is_desktop_window(AXUIElementRef _window) {
    bool desktop_window = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        desktop_window = AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos) &&
            NSEqualPoints(NSPointFromCGPoint(cg_pos), NSPointFromCGPoint(desktopOrigin));
        CFRelease(_pos);
    }

    if (verbose && desktop_window) { NSLog(@"Desktop window"); }
    return desktop_window;
}

inline bool is_full_screen(AXUIElementRef _window) {
    bool full_screen = false;
    AXValueRef _pos = NULL;
    AXUIElementCopyAttributeValue(_window, kAXPositionAttribute, (CFTypeRef *) &_pos);
    if (_pos) {
        CGPoint cg_pos;
        if (AXValueGetValue(_pos, kAXValueTypeCGPoint, &cg_pos)) {
            NSScreen * screen = findScreen(cg_pos);
            if (screen) {
                AXValueRef _size = NULL;
                AXUIElementCopyAttributeValue(_window, kAXSizeAttribute, (CFTypeRef *) &_size);
                if (_size) {
                    CGSize cg_size;
                    if (AXValueGetValue(_size, kAXValueTypeCGSize, &cg_size)) {
                        float menuBarHeight =
                            fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                        NSScreen * main_screen = NSScreen.screens[0];
                        float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);
                        full_screen = cg_pos.x == NSMinX(screen.frame) &&
                                      cg_pos.y == screenOriginY + menuBarHeight &&
                                      cg_size.width == NSWidth(screen.frame) &&
                                      cg_size.height == NSHeight(screen.frame) - menuBarHeight;
                    }
                    CFRelease(_size);
                }
            }
        }
        CFRelease(_pos);
    }

    if (verbose && full_screen) { NSLog(@"Full screen window"); }
    return full_screen;
}

inline bool is_main_window(AXUIElementRef _app, AXUIElementRef _window, bool chrome_app) {
    bool main_window = false;
    CFBooleanRef _result = NULL;
    AXUIElementCopyAttributeValue(_window, kAXMainAttribute, (CFTypeRef *) &_result);
    if (_result) {
        main_window = CFEqual(_result, kCFBooleanTrue);
        if (main_window) {
            CFStringRef _element_sub_role = NULL;
            AXUIElementCopyAttributeValue(_window, kAXSubroleAttribute, (CFTypeRef *) &_element_sub_role);
            if (_element_sub_role) {
                main_window = !CFEqual(_element_sub_role, kAXDialogSubrole);
                if (verbose && !main_window) { NSLog(@"Dialog window"); }
                CFRelease(_element_sub_role);
            }
        }
        CFRelease(_result);
    }

    bool finder_app = titleEquals(_app, @[Finder]);
    main_window = main_window && (chrome_app || finder_app ||
        !titleEquals(_window, @[NoTitle]) ||
        titleEquals(_app, mainWindowAppsWithoutTitle));

    main_window = main_window || (!finder_app && is_full_screen(_window));

    if (verbose && !main_window) { NSLog(@"Not a main window"); }
    return main_window;
}

inline bool is_pwa(NSString * bundleIdentifier) {
    NSArray * components = [bundleIdentifier componentsSeparatedByString: @"."];
    bool pake = components.count == 3 && [components[1] isEqual: Pake];
    bool pwa = pake || (components.count > 4 &&
        [pwas containsObject: components[2]] && [components[3] isEqual: @"app"]);
    if (verbose && pwa) { NSLog(@"PWA: %@", components[2]); }
    return pwa;
}

//-----------------------------------------------notifications----------------------------------------------

void spaceChanged();
bool appActivated();
void performRaiseCheck(CGPoint mousePoint);

@interface MDWorkspaceWatcher:NSObject {}
- (id)init;
@end

static MDWorkspaceWatcher * workspaceWatcher = NULL;

@implementation MDWorkspaceWatcher
- (id)init {
    if ((self = [super init])) {
        NSNotificationCenter * center =
            [[NSWorkspace sharedWorkspace] notificationCenter];
        [center
            addObserver: self
            selector: @selector(spaceChanged:)
            name: NSWorkspaceActiveSpaceDidChangeNotification
            object: nil];
        if (warpMouse) {
            [center
                addObserver: self
                selector: @selector(appActivated:)
                name: NSWorkspaceDidActivateApplicationNotification
                object: nil];
            if (verbose) { NSLog(@"Registered app activated selector"); }
        }
    }
    return self;
}

- (void)dealloc {
    [[[NSWorkspace sharedWorkspace] notificationCenter] removeObserver: self];
}

- (void)spaceChanged:(NSNotification *)notification {
    if (verbose) { NSLog(@"Space changed"); }
    spaceChanged();
}

- (void)appActivated:(NSNotification *)notification {
    if (verbose) { NSLog(@"App activated, waiting %0.3fs", ACTIVATE_DELAY_MS/1000.0); }
    [self performSelector: @selector(onAppActivated) withObject: nil afterDelay: ACTIVATE_DELAY_MS/1000.0];
}

- (void)onAppActivated {
    if (appActivated() && cursorScale != oldScale) {
        if (verbose) { NSLog(@"Set cursor scale after %0.3fs", SCALE_DELAY_MS/1000.0); }
        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: cursorScale]
            afterDelay: SCALE_DELAY_MS/1000.0];

        [self performSelector: @selector(onSetCursorScale:)
            withObject: [NSNumber numberWithFloat: oldScale]
            afterDelay: SCALE_DURATION_MS/1000.0];
    }
}

- (void)onSetCursorScale:(NSNumber *)scale {
    if (verbose) { NSLog(@"Set cursor scale: %@", scale); }
    CGSSetCursorScale(CGSMainConnectionID(), scale.floatValue);
}
@end // MDWorkspaceWatcher

//----------------------------------------------configuration-----------------------------------------------

const NSString *kWarpX = @"warpX";
const NSString *kWarpY = @"warpY";
const NSString *kScale = @"scale";
const NSString *kVerbose = @"verbose";
const NSString *kAltTaskSwitcher = @"altTaskSwitcher";
const NSString *kIgnoreSpaceChanged = @"ignoreSpaceChanged";
const NSString *kStayFocusedBundleIds = @"stayFocusedBundleIds";
const NSString *kInvertDisableKey = @"invertDisableKey";
const NSString *kInvertIgnoreApps = @"invertIgnoreApps";
const NSString *kIgnoreApps = @"ignoreApps";
const NSString *kIgnoreTitles = @"ignoreTitles";
const NSString *kPollMillis = @"pollMillis";
const NSString *kDisableKey = @"disableKey";
NSArray *parametersDictionary = @[kWarpX, kWarpY, kScale, kVerbose, kAltTaskSwitcher,
    kIgnoreSpaceChanged, kInvertDisableKey, kInvertIgnoreApps, kIgnoreApps,
    kIgnoreTitles, kStayFocusedBundleIds, kDisableKey, kPollMillis];

// Keys removed in AutoRaise 6.0. Present in older configs/CLI invocations; we warn
// and strip them so users aren't silently broken.
NSArray *deprecatedKeys = @[@"delay", @"focusDelay", @"requireMouseStop", @"mouseDelta"];

NSMutableDictionary *parameters = [[NSMutableDictionary alloc] init];

@interface ConfigClass:NSObject
- (NSString *) getFilePath:(NSString *) filename;
- (NSString *) findConfigFilePath;
- (void) readConfig:(int) argc;
- (void) readHiddenConfig;
- (void) warnAndStripDeprecated;
- (void) rewriteConfigStrippingDeprecatedKeys;
- (void) validateParameters;
@end

@implementation ConfigClass
- (NSString *) getFilePath:(NSString *) filename {
    filename = [NSString stringWithFormat: @"%@/%@", NSHomeDirectory(), filename];
    if (not [[NSFileManager defaultManager] fileExistsAtPath: filename]) { filename = NULL; }
    return filename;
}

- (NSString *) findConfigFilePath {
    NSString * path = [self getFilePath: @".AutoRaise"];
    if (!path) { path = [self getFilePath: @".config/AutoRaise/config"]; }
    return path;
}

- (void) readConfig:(int) argc {
    if (argc > 1) {
        // read NSArgumentDomain
        NSUserDefaults *arguments = [NSUserDefaults standardUserDefaults];

        for (id key in parametersDictionary) {
            id arg = [arguments objectForKey: key];
            if (arg != NULL) { parameters[key] = arg; }
        }
        // Also read deprecated keys from CLI so we can warn about them below.
        for (id key in deprecatedKeys) {
            id arg = [arguments objectForKey: key];
            if (arg != NULL) { parameters[key] = arg; }
        }
    } else {
        [self readHiddenConfig];
    }
    return;
}

- (void) readHiddenConfig {
    // search for dotfiles
    NSString * hiddenConfigFilePath = [self findConfigFilePath];

    if (hiddenConfigFilePath) {
        NSError * error;
        NSString * configContent = [[NSString alloc]
            initWithContentsOfFile: hiddenConfigFilePath
            encoding: NSUTF8StringEncoding error: &error];

        NSArray * configLines = [configContent componentsSeparatedByString: @"\n"];
        NSString * trimmedLine, * trimmedKey, * trimmedValue, * noQuotesValue;
        NSArray * components;
        NSArray * allKnownKeys = [parametersDictionary arrayByAddingObjectsFromArray: deprecatedKeys];
        for (NSString * line in configLines) {
            trimmedLine = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
            if (not [trimmedLine hasPrefix: @"#"]) {
                components = [trimmedLine componentsSeparatedByString: @"="];
                if ([components count] == 2) {
                    for (id key in allKnownKeys) {
                       trimmedKey = [components[0] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       trimmedValue = [components[1] stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
                       noQuotesValue = [trimmedValue stringByReplacingOccurrencesOfString: @"\"" withString: @""];
                       if ([trimmedKey isEqual: key]) { parameters[key] = noQuotesValue; }
                    }
                }
            }
        }
    }
    return;
}

- (void) warnAndStripDeprecated {
    for (NSString * key in deprecatedKeys) {
        if (parameters[key]) {
            fprintf(stderr, "Warning: %s is deprecated and has been removed in AutoRaise 6.0; ignoring\n",
                [key UTF8String]);
            [parameters removeObjectForKey: key];
        }
    }
}

- (void) rewriteConfigStrippingDeprecatedKeys {
    NSString * path = [self findConfigFilePath];
    if (!path) { return; }

    NSError * error = nil;
    NSString * content = [[NSString alloc]
        initWithContentsOfFile: path
        encoding: NSUTF8StringEncoding error: &error];
    if (!content) { return; }

    NSArray * lines = [content componentsSeparatedByString: @"\n"];
    NSMutableArray * kept = [NSMutableArray arrayWithCapacity: lines.count];
    bool changed = false;

    for (NSString * line in lines) {
        NSString * trimmed = [line stringByTrimmingCharactersInSet: [NSCharacterSet whitespaceCharacterSet]];
        bool strip = false;
        if (![trimmed hasPrefix: @"#"] && trimmed.length > 0) {
            NSArray * components = [trimmed componentsSeparatedByString: @"="];
            if (components.count == 2) {
                NSString * key = [components[0] stringByTrimmingCharactersInSet:
                    [NSCharacterSet whitespaceCharacterSet]];
                if ([deprecatedKeys containsObject: key]) { strip = true; }
            }
        }
        if (strip) { changed = true; }
        else { [kept addObject: line]; }
    }

    if (!changed) { return; }

    NSString * rewritten = [kept componentsJoinedByString: @"\n"];
    NSError * writeError = nil;
    if (![rewritten writeToFile: path atomically: YES
                       encoding: NSUTF8StringEncoding error: &writeError]) {
        fprintf(stderr, "Warning: could not rewrite config file at %s: %s\n",
            [path UTF8String],
            writeError ? [[writeError localizedDescription] UTF8String] : "unknown error");
    } else if (verbose) {
        NSLog(@"Config rewritten: deprecated keys stripped from %@", path);
    }
}

- (void) validateParameters {
    // validate and fix wrong/absent parameters
    if (!parameters[kPollMillis]) { parameters[kPollMillis] = @"8"; }
    else if ([parameters[kPollMillis] intValue] < 1) { parameters[kPollMillis] = @"1"; }
    if ([parameters[kScale] floatValue] < 1) { parameters[kScale] = @"2.0"; }
    if (!parameters[kDisableKey]) { parameters[kDisableKey] = @"control"; }
    warpMouse =
        parameters[kWarpX] && [parameters[kWarpX] floatValue] >= 0 && [parameters[kWarpX] floatValue] <= 1 &&
        parameters[kWarpY] && [parameters[kWarpY] floatValue] >= 0 && [parameters[kWarpY] floatValue] <= 1;
#ifdef ALTERNATIVE_TASK_SWITCHER
    if (!parameters[kAltTaskSwitcher]) { parameters[kAltTaskSwitcher] = @"true"; }
#endif
    return;
}
@end // ConfigClass

//------------------------------------------where it all happens--------------------------------------------

void spaceChanged() {
    if (ignoreSpaceChanged) { return; }

    CGEventRef _event = CGEventCreate(NULL);
    CGPoint mousePoint = CGEventGetLocation(_event);
    if (_event) { CFRelease(_event); }

    // Reset oldPoint so appActivated's mouse-movement heuristic treats this as
    // a fresh position, matching prior behavior.
    oldPoint.x = oldPoint.y = 0;

    performRaiseCheck(mousePoint);
}

bool appActivated() {
    if (verbose) { NSLog(@"App activated"); }

    // Open a suppression window so incidental mouse-moved events during warp +
    // window settle don't raise the wrong window. The post-warp performRaiseCheck
    // below is invoked directly and bypasses this gate (which only applies in the
    // mouse-moved tap path).
    suppressRaisesUntil = currentTimeMillis() + SUPPRESS_MS;

    if (!altTaskSwitcher) {
        if (!activated_by_task_switcher) { return false; }
        activated_by_task_switcher = false;
    }

    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    pid_t frontmost_pid = frontmostApp.processIdentifier;

    AXUIElementRef _activatedWindow = NULL;
    AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
    AXUIElementCopyAttributeValue(_frontmostApp,
        kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
    if (!_activatedWindow) {
        if (verbose) { NSLog(@"No main window, trying focused window"); }
        AXUIElementCopyAttributeValue(_frontmostApp,
            kAXFocusedWindowAttribute, (CFTypeRef *) &_activatedWindow);
    }
    CFRelease(_frontmostApp);

    if (verbose) { NSLog(@"BundleIdentifier: %@", frontmostApp.bundleIdentifier); }
    bool finder_app = [frontmostApp.bundleIdentifier isEqual: FinderBundleId];
    if (finder_app) {
        if (_activatedWindow) {
            if (is_desktop_window(_activatedWindow)) {
                CFRelease(_activatedWindow);
                _activatedWindow = _previousFinderWindow;
            } else {
                if (_previousFinderWindow) { CFRelease(_previousFinderWindow); }
                _previousFinderWindow = _activatedWindow;
            }
        } else { _activatedWindow = _previousFinderWindow; }
    }

    if (altTaskSwitcher) {
        CGEventRef _event = CGEventCreate(NULL);
        CGPoint mousePoint = CGEventGetLocation(_event);
        if (_event) { CFRelease(_event); }

        bool ignoreActivated = false;
        // TODO: is the uncorrected mousePoint good enough?
        AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
        if (_mouseWindow) {
            if (!activated_by_task_switcher) {
                pid_t mouseWindow_pid;
                // Checking for mouse movement reduces the problem of the mouse being warped
                // when changing spaces and simultaneously moving the mouse to another screen
                ignoreActivated = fabs(mousePoint.x-oldPoint.x) > 0;
                ignoreActivated = ignoreActivated || fabs(mousePoint.y-oldPoint.y) > 0;
                // Check if the mouse is already hovering above the frontmost app. If
                // for example we only change spaces, we don't want the mouse to warp
                ignoreActivated = ignoreActivated || (AXUIElementGetPid(_mouseWindow,
                    &mouseWindow_pid) == kAXErrorSuccess && mouseWindow_pid == frontmost_pid);
            }
            CFRelease(_mouseWindow);
        } else { // dock or top menu
            // Comment the line below if clicking the dock icons should also
            // warp the mouse. Note this may introduce some unexpected warps
            ignoreActivated = true;
        }

        activated_by_task_switcher = false; // used in the previous code block

        if (ignoreActivated) {
            if (verbose) { NSLog(@"Ignoring app activated"); }
            if (!finder_app && _activatedWindow) { CFRelease(_activatedWindow); }
            return false;
        }
    }

    if (_activatedWindow) {
        if (verbose) { NSLog(@"Warp mouse"); }
        CGPoint warpTarget = get_mousepoint(_activatedWindow);
        CGWarpMouseCursorPosition(warpTarget);
        if (!finder_app) { CFRelease(_activatedWindow); }

        // CGWarpMouseCursorPosition does not emit a kCGEventMouseMoved event, so the
        // event-tap path won't notice the cursor's new position. Fire a raise check
        // explicitly against the warp target to ensure the newly-activated app's
        // window is raised (if not already frontmost).
        performRaiseCheck(warpTarget);
    }

    return true;
}

void AXCallback(AXObserverRef observer, AXUIElementRef _element, CFStringRef notification, void * destroyedMouseWindow_id) {
    if (CFEqual(notification, kAXUIElementDestroyedNotification)) {
        lastDestroyedMouseWindow_id = (uint64_t) destroyedMouseWindow_id;
    }
}

void performRaiseCheck(CGPoint mousePoint) {
    // Every call increments the generation counter — including calls that abort
    // early or find no raise needed. This cancels any in-flight retries from a
    // previous window as soon as the cursor moves onto a different area
    // (ignored app, current frontmost, disableKey held, dock/mc active, etc.),
    // preventing stale retries from stealing focus back to an old window.
    uint64_t gen = ++raiseGeneration;

    // Corner correction (macOS 12+): direction based on delta from previous point.
    float mouse_x_diff = mousePoint.x - oldPoint.x;
    float mouse_y_diff = mousePoint.y - oldPoint.y;
    oldPoint = mousePoint;

    if (@available(macOS 12.00, *)) {
        if (fabs(mouse_x_diff) > 0 || fabs(mouse_y_diff) > 0) {
            NSScreen * screen = findScreen(mousePoint);
            mousePoint.x += mouse_x_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
            mousePoint.y += mouse_y_diff > 0 ? WINDOW_CORRECTION : -WINDOW_CORRECTION;
            if (screen) {
                NSScreen * main_screen = NSScreen.screens[0];
                float screenOriginX = NSMinX(screen.frame) - NSMinX(main_screen.frame);
                float screenOriginY = NSMaxY(main_screen.frame) - NSMaxY(screen.frame);

                if (oldPoint.x > screenOriginX + NSWidth(screen.frame) - WINDOW_CORRECTION) {
                    if (verbose) { NSLog(@"Screen edge correction"); }
                    mousePoint.x = screenOriginX + NSWidth(screen.frame) - SCREEN_EDGE_CORRECTION;
                } else if (oldPoint.x < screenOriginX + WINDOW_CORRECTION - 1) {
                    if (verbose) { NSLog(@"Screen edge correction"); }
                    mousePoint.x = screenOriginX + SCREEN_EDGE_CORRECTION;
                }

                if (oldPoint.y > screenOriginY + NSHeight(screen.frame) - WINDOW_CORRECTION) {
                    if (verbose) { NSLog(@"Screen edge correction"); }
                    mousePoint.y = screenOriginY + NSHeight(screen.frame) - SCREEN_EDGE_CORRECTION;
                } else {
                    float menuBarHeight = fmax(0, NSMaxY(screen.frame) - NSMaxY(screen.visibleFrame) - 1);
                    if (mousePoint.y < screenOriginY + menuBarHeight + MENUBAR_CORRECTION) {
                        if (verbose) { NSLog(@"Menu bar correction"); }
                        mousePoint.y = screenOriginY;
                    }
                }
            }
        }
    }

    // Abort: drag in progress, Dock/Mission Control active, disableKey held,
    // or frontmost app is pinned via stayFocusedBundleIds.
    bool abort = CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonLeft) ||
        CGEventSourceButtonState(kCGEventSourceStateCombinedSessionState, kCGMouseButtonRight) ||
        dock_active() || mc_active();

    if (!abort && disableKey) {
        CGEventRef _keyDownEvent = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventFlags flags = CGEventGetFlags(_keyDownEvent);
        if (_keyDownEvent) { CFRelease(_keyDownEvent); }
        abort = (flags & disableKey) == disableKey;
        abort = abort != invertDisableKey;
    }

    NSRunningApplication *frontmostApp = [[NSWorkspace sharedWorkspace] frontmostApplication];
    abort = abort || [stayFocusedBundleIds containsObject: frontmostApp.bundleIdentifier];

    if (abort) {
        if (verbose) { NSLog(@"Abort focus/raise"); }
        return;
    }

    AXUIElementRef _mouseWindow = get_mousewindow(mousePoint);
    if (!_mouseWindow) { return; }

    pid_t mouseWindow_pid;
    if (AXUIElementGetPid(_mouseWindow, &mouseWindow_pid) != kAXErrorSuccess) {
        CFRelease(_mouseWindow);
        return;
    }

    CGWindowID mouseWindow_id = kCGNullWindowID;
    if (_AXUIElementGetWindow(_mouseWindow, &mouseWindow_id) != kAXErrorSuccess) {
        if (verbose) { NSLog(@"No window id for mouse window"); }
        CFRelease(_mouseWindow);
        return;
    }
    bool mouseWindowPresent = mouseWindow_id != lastDestroyedMouseWindow_id;

    if (mouseWindowPresent) {
        static CGWindowID previous_id = kCGNullWindowID;
        if (mouseWindow_id != previous_id) {
            previous_id = mouseWindow_id;
            lastDestroyedMouseWindow_id = kCGNullWindowID;

            if (axObserver) {
                CFRelease(axObserver);
                axObserver = NULL;
            }

            if (AXObserverCreate(
                    mouseWindow_pid,
                    AXCallback,
                    &axObserver) == kAXErrorSuccess && axObserver) {
                AXObserverAddNotification(
                    axObserver,
                    _mouseWindow,
                    kAXUIElementDestroyedNotification,
                    (void *) ((uint64_t) mouseWindow_id)
                );

                CFRunLoopAddSource(
                    CFRunLoopGetCurrent(),
                    AXObserverGetRunLoopSource(axObserver),
                    kCFRunLoopCommonModes
                );
            } else {
                // Observer creation failed (e.g., app exited between PID lookup
                // and observer setup). Reset previous_id so the next raise-check
                // over the same window retries observer setup instead of being
                // skipped by the mouseWindow_id != previous_id guard above.
                if (verbose) { NSLog(@"AXObserverCreate failed"); }
                axObserver = NULL;
                previous_id = kCGNullWindowID;
            }
        }
    } else if (verbose) { NSLog(@"Mouse window not present"); }

    bool needs_raise = !invertIgnoreApps && mouseWindowPresent;
    AXUIElementRef _mouseWindowApp = AXUIElementCreateApplication(mouseWindow_pid);
    if (needs_raise && titleEquals(_mouseWindow, @[NoTitle, Untitled])) {
        needs_raise = is_main_window(_mouseWindowApp, _mouseWindow, is_pwa(
            [NSRunningApplication runningApplicationWithProcessIdentifier:
            mouseWindow_pid].bundleIdentifier));
        if (verbose && !needs_raise) { NSLog(@"Excluding window"); }
    } else if (needs_raise &&
        titleEquals(_mouseWindow, @[BartenderBar, Zim, AppStoreSearchResults], ignoreTitles)) {
        needs_raise = false;
        if (verbose) { NSLog(@"Excluding window"); }
    } else if (mouseWindowPresent) {
        if (titleEquals(_mouseWindowApp, ignoreApps)) {
            needs_raise = invertIgnoreApps;
            if (verbose) {
                if (invertIgnoreApps) {
                    NSLog(@"Including app");
                } else {
                    NSLog(@"Excluding app");
                }
            }
        }
    }
    CFRelease(_mouseWindowApp);

    if (needs_raise) {
        pid_t frontmost_pid = frontmostApp.processIdentifier;
        AXUIElementRef _frontmostApp = AXUIElementCreateApplication(frontmost_pid);
        AXUIElementRef _focusedWindow = NULL;
        AXUIElementCopyAttributeValue(
            _frontmostApp,
            kAXFocusedWindowAttribute,
            (CFTypeRef *) &_focusedWindow);
        if (_focusedWindow) {
            if (verbose) { logWindowTitle(@"Focused window", _focusedWindow); }
            CGWindowID focusedWindow_id = kCGNullWindowID;
            if (_AXUIElementGetWindow(_focusedWindow, &focusedWindow_id) == kAXErrorSuccess) {
                needs_raise = mouseWindow_id != focusedWindow_id;
                needs_raise = needs_raise && !contained_within(_focusedWindow, _mouseWindow);
            } else {
                // Focused window's ID could not be read; we can't verify
                // whether it's the same window the mouse is over. Skip the
                // raise rather than risk re-activating the already-focused
                // window (contained_within uses strict bounds, so identical
                // windows would otherwise fall through to a spurious raise).
                needs_raise = false;
            }
            CFRelease(_focusedWindow);
        } else {
            if (verbose) { NSLog(@"No focused window"); }
            AXUIElementRef _activatedWindow = NULL;
            AXUIElementCopyAttributeValue(_frontmostApp,
                kAXMainWindowAttribute, (CFTypeRef *) &_activatedWindow);
            if (_activatedWindow) {
              needs_raise = false;
              CFRelease(_activatedWindow);
            }
        }
        CFRelease(_frontmostApp);
    }

    if (needs_raise) {
        raiseAndActivate(_mouseWindow, mouseWindow_pid);

        // Schedule two retry raises for apps that don't respect the first one
        // (Finder, some Electron apps). Each retry captures `gen` and only fires
        // if no newer raise has been issued in the meantime.
        pid_t captured_pid = mouseWindow_pid;

        AXUIElementRef _win1 = (AXUIElementRef) CFRetain(_mouseWindow);
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t) RAISE_RETRY_1_MS * NSEC_PER_MSEC),
            dispatch_get_main_queue(),
            ^{
                if (gen == raiseGeneration) {
                    raiseAndActivate(_win1, captured_pid);
                }
                CFRelease(_win1);
            }
        );

        AXUIElementRef _win2 = (AXUIElementRef) CFRetain(_mouseWindow);
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t) RAISE_RETRY_2_MS * NSEC_PER_MSEC),
            dispatch_get_main_queue(),
            ^{
                if (gen == raiseGeneration) {
                    raiseAndActivate(_win2, captured_pid);
                }
                CFRelease(_win2);
            }
        );
    }

    CFRelease(_mouseWindow);
}

CGEventRef eventTapHandler(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    // Mouse-moved: throttled + suppression-gated raise check.
    // IMPORTANT: always return `event` unmodified. This tap is listen-only; dropping
    // or mutating the event would break the user's mouse.
    if (type == kCGEventMouseMoved) {
        double now = currentTimeMillis();
        if (now - lastCheckTime < (double) pollMillis) { return event; }
        if (now < suppressRaisesUntil) { return event; }
        lastCheckTime = now;
        CGPoint mousePoint = CGEventGetLocation(event);
        performRaiseCheck(mousePoint);
        return event;
    }

    CGEventFlags flags = CGEventGetFlags(event);
    bool commandPressed = (flags & TASK_SWITCHER_MODIFIER_KEY) == TASK_SWITCHER_MODIFIER_KEY;

    static bool commandTabPressed = false;
    if (!commandPressed && commandTabPressed) {
        commandTabPressed = false;
        activated_by_task_switcher = true;
        // Open suppression window now — app activation notification will arrive soon.
        suppressRaisesUntil = currentTimeMillis() + SUPPRESS_MS;
    }

    static bool commandGravePressed = false;
    if (!commandPressed && commandGravePressed) {
        commandGravePressed = false;
        activated_by_task_switcher = true;
        suppressRaisesUntil = currentTimeMillis() + SUPPRESS_MS;
        [workspaceWatcher onAppActivated];
    }

    if (type == kCGEventKeyDown) {
        CGKeyCode keycode = (CGKeyCode) CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
        if (keycode == kVK_Tab) {
            commandTabPressed = commandTabPressed || commandPressed;
        } else if (warpMouse && keycode == kVK_ANSI_Grave) {
            commandGravePressed = commandGravePressed || commandPressed;
        }
    } else if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (verbose) { NSLog(@"Got event tap disabled event, re-enabling..."); }
        CGEventTapEnable(eventTap, true);
    }

    return event;
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        ConfigClass * config = [[ConfigClass alloc] init];
        [config readConfig: argc];
        [config warnAndStripDeprecated];
        [config rewriteConfigStrippingDeprecatedKeys];
        [config validateParameters];

        warpX              = [parameters[kWarpX] floatValue];
        warpY              = [parameters[kWarpY] floatValue];
        cursorScale        = [parameters[kScale] floatValue];
        verbose            = [parameters[kVerbose] boolValue];
        altTaskSwitcher    = [parameters[kAltTaskSwitcher] boolValue];
        pollMillis         = [parameters[kPollMillis] intValue];
        ignoreSpaceChanged = [parameters[kIgnoreSpaceChanged] boolValue];
        invertIgnoreApps   = [parameters[kInvertIgnoreApps] boolValue];
        invertDisableKey   = [parameters[kInvertDisableKey] boolValue];

        printf("\nv%s by sbmpost(c) 2026, usage:\n\nAutoRaise\n", AUTORAISE_VERSION);
        printf("  -pollMillis <1, 2, ..., 8, ..., 50, ...>  (default 8)\n");
        printf("  -warpX <0.5> -warpY <0.5> -scale <2.0>\n");
        printf("  -altTaskSwitcher <true|false>\n");
        printf("  -ignoreSpaceChanged <true|false>\n");
        printf("  -invertDisableKey <true|false>\n");
        printf("  -invertIgnoreApps <true|false>\n");
        printf("  -ignoreApps \"<App1,App2,...>\"\n");
        printf("  -ignoreTitles \"<Regex1,Regex2,...>\"\n");
        printf("  -stayFocusedBundleIds \"<Id1,Id2,...>\"\n");
        printf("  -disableKey <control|option|disabled>\n");
        printf("  -verbose <true|false>\n\n");

        printf("Started with:\n");
        printf("  * pollMillis: %dms\n", pollMillis);

        if (warpMouse) {
            printf("  * warpX: %.1f, warpY: %.1f, scale: %.1f\n", warpX, warpY, cursorScale);
            printf("  * altTaskSwitcher: %s\n", altTaskSwitcher ? "true" : "false");
        }

        printf("  * ignoreSpaceChanged: %s\n", ignoreSpaceChanged ? "true" : "false");
        printf("  * invertDisableKey: %s\n", invertDisableKey ? "true" : "false");
        printf("  * invertIgnoreApps: %s\n", invertIgnoreApps ? "true" : "false");

        NSMutableArray * ignoreA;
        if (parameters[kIgnoreApps]) {
            ignoreA = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreApps] componentsSeparatedByString:@","]];
        } else { ignoreA = [[NSMutableArray alloc] init]; }

        for (id ignoreApp in ignoreA) {
            printf("  * ignoreApp: %s\n", [ignoreApp UTF8String]);
        }
        [ignoreA addObject: AssistiveControl];
        ignoreApps = [ignoreA copy];

        NSMutableArray * ignoreT;
        if (parameters[kIgnoreTitles]) {
            ignoreT = [[NSMutableArray alloc] initWithArray:
                [parameters[kIgnoreTitles] componentsSeparatedByString: @","]];
        } else { ignoreT = [[NSMutableArray alloc] init]; }

        for (id ignoreTitle in ignoreT) {
            printf("  * ignoreTitle: %s\n", [ignoreTitle UTF8String]);
        }
        ignoreTitles = [ignoreT copy];

        NSMutableArray * stayFocused;
        if (parameters[kStayFocusedBundleIds]) {
            stayFocused = [[NSMutableArray alloc] initWithArray:
                [parameters[kStayFocusedBundleIds] componentsSeparatedByString: @","]];
        } else { stayFocused = [[NSMutableArray alloc] init]; }

        for (id stayFocusedBundleId in stayFocused) {
            printf("  * stayFocusedBundleId: %s\n", [stayFocusedBundleId UTF8String]);
        }
        stayFocusedBundleIds = [stayFocused copy];

        if ([parameters[kDisableKey] isEqualToString: @"control"]) {
            printf("  * disableKey: control\n");
            disableKey = kCGEventFlagMaskControl;
        } else if ([parameters[kDisableKey] isEqualToString: @"option"]) {
            printf("  * disableKey: option\n");
            disableKey = kCGEventFlagMaskAlternate;
        } else { printf("  * disableKey: disabled\n"); }

        printf("  * verbose: %s\n", verbose ? "true" : "false");
#if defined OLD_ACTIVATION_METHOD or defined ALTERNATIVE_TASK_SWITCHER
        printf("\nCompiled with:\n");
#ifdef OLD_ACTIVATION_METHOD
        printf("  * OLD_ACTIVATION_METHOD\n");
#endif
#ifdef ALTERNATIVE_TASK_SWITCHER
        printf("  * ALTERNATIVE_TASK_SWITCHER\n");
#endif
#endif
        printf("\n");

        NSDictionary * options = @{(id) CFBridgingRelease(kAXTrustedCheckOptionPrompt): @YES};
        bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef) options);
        if (verbose) { NSLog(@"AXIsProcessTrusted: %s", trusted ? "YES" : "NO"); }

        CGSGetCursorScale(CGSMainConnectionID(), &oldScale);
        if (verbose) { NSLog(@"System cursor scale: %f", oldScale); }

        CFRunLoopSourceRef runLoopSource = NULL;
        eventTap = CGEventTapCreate(
            kCGSessionEventTap,
            kCGHeadInsertEventTap,
            kCGEventTapOptionListenOnly,
            CGEventMaskBit(kCGEventKeyDown) |
            CGEventMaskBit(kCGEventFlagsChanged) |
            CGEventMaskBit(kCGEventMouseMoved),
            eventTapHandler,
            NULL
        );
        if (eventTap) {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0);
            if (runLoopSource) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, kCFRunLoopCommonModes);
                CGEventTapEnable(eventTap, true);
            }
        }
        if (verbose) { NSLog(@"Got run loop source: %s", runLoopSource ? "YES" : "NO"); }

        workspaceWatcher = [[MDWorkspaceWatcher alloc] init];

        findDockApplication();
        findDesktopOrigin();
        [[NSApplication sharedApplication] run];
    }
    return 0;
}
