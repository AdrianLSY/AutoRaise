## ADDED Requirements

### Requirement: Mouse tracking uses an extended CGEventTap
AutoRaise SHALL observe mouse movement by extending the existing event-tap's mask with `kCGEventMouseMoved`, attached to the main thread's `CFRunLoop` in default mode. No `NSTimer` or `performSelector:afterDelay:` polling loop drives mouse tracking.

#### Scenario: Tap installs successfully at startup
- **WHEN** AutoRaise starts with accessibility permission granted
- **THEN** a single `CGEventTap` configured with `kCGAnnotatedSessionEventTap` placement and `kCGEventTapOptionListenOnly` options SHALL be installed for both keyboard events (existing cmd-tab detection) and `kCGEventMouseMoved` events

#### Scenario: Tap fails to install
- **WHEN** AutoRaise cannot create the event tap (e.g., accessibility permission revoked)
- **THEN** AutoRaise SHALL log the failure and exit with a non-zero status

#### Scenario: Mouse idle
- **WHEN** the mouse does not move for any duration
- **THEN** no timer or periodic handler SHALL fire and AutoRaise SHALL use zero CPU for mouse tracking

### Requirement: Event tap callback always passes events through unmodified
The event-tap callback SHALL return the received `CGEvent` pointer unmodified for every event type, including mouse-moved events that are throttled, suppressed, or result in a raise. The callback SHALL NOT drop, consume, or mutate events.

#### Scenario: Mouse-moved event throttled
- **WHEN** a `kCGEventMouseMoved` event is dropped by the throttle
- **THEN** the callback SHALL still return the event unmodified so macOS delivers it to the foreground app

#### Scenario: Mouse-moved event triggers raise
- **WHEN** a `kCGEventMouseMoved` event causes a raise
- **THEN** the callback SHALL return the event unmodified before, during, or after the raise is issued

#### Scenario: Tap disabled by timeout
- **WHEN** the callback receives `kCGEventTapDisabledByTimeout` or `kCGEventTapDisabledByUserInput`
- **THEN** it SHALL call `CGEventTapEnable(tap, true)` to re-enable the tap and return the event unmodified

### Requirement: Mouse events are rate-limited by pollMillis
AutoRaise SHALL maintain a monotonic `lastCheckTime` timestamp (using `mach_absolute_time` or `CACurrentMediaTime` — never wall clock) and drop incoming mouse-moved events that arrive within `pollMillis` milliseconds of the previous accepted event, without performing any AX lookup.

#### Scenario: Rapid mouse events during a flick
- **WHEN** the hardware delivers 1000 mouse-moved events per second and `pollMillis = 8`
- **THEN** AutoRaise SHALL perform at most 125 raise checks per second, dropping intermediate events

#### Scenario: pollMillis minimum
- **WHEN** the user supplies `pollMillis < 1`
- **THEN** AutoRaise SHALL clamp `pollMillis` to 1

#### Scenario: pollMillis default
- **WHEN** no `pollMillis` value is provided via CLI, config file, or NSArgumentDomain
- **THEN** AutoRaise SHALL use `pollMillis = 8`

#### Scenario: Discrete events bypass throttle
- **WHEN** a space-change or post-warp raise check is triggered
- **THEN** the throttle SHALL NOT apply and the check runs immediately

### Requirement: Raise fires on every window-under-cursor change
AutoRaise SHALL raise the hovered window whenever it differs from the frontmost focused window, without any settle time, debounce, multi-tick delay, or mouse-movement filter.

#### Scenario: Hovering into a new window
- **WHEN** the cursor crosses from window A into window B
- **THEN** window B SHALL be raised on the next accepted mouse-moved event, regardless of whether the mouse is still moving

#### Scenario: Flicking across multiple overlapping windows
- **WHEN** the cursor sweeps across three overlapping windows A → B → C in under one second
- **THEN** AutoRaise SHALL raise each window as the cursor enters it, subject only to the `pollMillis` throttle

#### Scenario: Hovered window unchanged
- **WHEN** a mouse-moved event is accepted but the hovered window is the same as the frontmost focused window
- **THEN** no raise is issued and the generation counter SHALL NOT be incremented

### Requirement: Raise retries use dispatch_after with generation cancellation
AutoRaise SHALL schedule two follow-up raise attempts via `dispatch_after` at fixed 50ms and 100ms offsets from the initial raise. A monotonic `raiseGeneration` counter SHALL gate retry execution: each scheduled retry captures `gen` at schedule time and runs only if `gen == raiseGeneration` at execution time.

#### Scenario: App does not respect first raise
- **WHEN** a Finder or Electron window receives an initial raise but remains behind another window
- **THEN** two further raise attempts SHALL fire at 50ms and 100ms after the initial raise, allowing the app a second and third chance to come forward

#### Scenario: Hovered window changes before retries fire
- **WHEN** the cursor moves to a different window between the initial raise and a scheduled retry, causing a new `performRaiseCheck` that increments `raiseGeneration`
- **THEN** the stale retry SHALL observe `gen != raiseGeneration` at execution time and SHALL NOT issue a raise

#### Scenario: Retry intervals are independent of pollMillis
- **WHEN** `pollMillis` is set to 1 or to 200
- **THEN** retries SHALL still fire at 50ms and 100ms after the initial raise

### Requirement: App activation opens a suppression window
When an app activation is detected (including via cmd-tab), AutoRaise SHALL set `suppressRaisesUntil = now + 150ms`. Mouse-moved events arriving before `suppressRaisesUntil` SHALL be dropped without any AX lookup.

#### Scenario: Cmd-tab with mouse still over the old window
- **WHEN** the user cmd-tabs away from the app under the cursor
- **THEN** for 150ms after activation, incidental mouse-moved events SHALL NOT trigger a raise of the old window

#### Scenario: Post-warp raise bypasses suppression
- **WHEN** `CGWarpMouseCursorPosition` moves the cursor to a new window and the app-activated handler calls `performRaiseCheck(warpTarget)`
- **THEN** the call SHALL proceed regardless of `suppressRaisesUntil` because the suppression gate is applied only in the mouse-moved tap path

### Requirement: CGWarpMouseCursorPosition is followed by an explicit raise check
Because `CGWarpMouseCursorPosition` teleports the cursor without generating a `kCGEventMouseMoved` event, the app-activated handler SHALL call `performRaiseCheck(warpTargetPoint)` immediately after the warp completes.

#### Scenario: Cmd-tab with warping enabled
- **WHEN** the user cmd-tabs while `warpX` and `warpY` are set, causing the cursor to teleport to the new app's window
- **THEN** `performRaiseCheck` SHALL be called with the warp target point to ensure that window is raised (if not already frontmost)

### Requirement: Screen-edge corner correction runs during raise checks
The screen-edge and menu-bar corner correction logic (previously inside `onTick`) SHALL be preserved inside `performRaiseCheck`, applied to the mouse point before the hovered-window lookup.

#### Scenario: Mouse near right screen edge
- **WHEN** the cursor is within `WINDOW_CORRECTION` pixels of the right edge of a screen on macOS 12+
- **THEN** the lookup point is adjusted inward by the correction offset before `get_mousewindow` is called

### Requirement: Abort conditions prevent raise
AutoRaise SHALL skip the raise (including scheduled retries — the generation counter is not incremented) if any of the following conditions hold at the time of the check.

#### Scenario: Mouse button held
- **WHEN** the left, right, or other mouse button is pressed during the check
- **THEN** no raise is issued

#### Scenario: Dock or Mission Control active
- **WHEN** `dock_active()` or `mc_active()` returns true
- **THEN** no raise is issued

#### Scenario: disableKey held
- **WHEN** the `disableKey` modifier is held and `invertDisableKey` is false
- **THEN** no raise is issued

#### Scenario: Frontmost app in stayFocusedBundleIds
- **WHEN** the frontmost app's bundle ID matches any entry in `stayFocusedBundleIds`
- **THEN** no raise is issued regardless of which window is hovered

#### Scenario: Hovered app in ignoreApps
- **WHEN** the hovered app matches `ignoreApps` and `invertIgnoreApps` is false
- **THEN** no raise is issued

#### Scenario: Hovered title in ignoreTitles
- **WHEN** the hovered window's title matches an `ignoreTitles` pattern
- **THEN** no raise is issued

### Requirement: Space change triggers an immediate raise check
When the active macOS Space changes, AutoRaise SHALL call `performRaiseCheck` for the current cursor position, bypassing throttle and suppression, unless `ignoreSpaceChanged` is true.

#### Scenario: User switches Space via gesture
- **WHEN** `NSWorkspaceActiveSpaceDidChangeNotification` fires and `ignoreSpaceChanged` is false
- **THEN** AutoRaise SHALL retrieve the current cursor position and invoke `performRaiseCheck` directly, which then issues the initial raise and the two standard retries

#### Scenario: ignoreSpaceChanged is true
- **WHEN** `ignoreSpaceChanged` is true at the time of a Space change
- **THEN** no raise is triggered by the Space change; the next mouse-moved event handles it normally

### Requirement: Config file deprecated keys are migrated
AutoRaise SHALL detect deprecated config keys (`delay`, `focusDelay`, `requireMouseStop`, `mouseDelta`) at startup, warn the user, strip them from the runtime parameters, and rewrite the config file preserving comments, unknown lines, and the relative ordering of retained keys.

#### Scenario: User has an old config with delay=1
- **WHEN** AutoRaise 6.0 starts and finds `delay=1` in the config file
- **THEN** it SHALL log `Warning: delay is deprecated and has been removed in AutoRaise 6.0; ignoring` to stderr, remove the key from in-memory parameters, and rewrite the config file with the `delay=1` line removed

#### Scenario: Multiple deprecated keys present
- **WHEN** the config contains both `mouseDelta=0.1` and `requireMouseStop=true`
- **THEN** AutoRaise SHALL emit one warning per deprecated key and the rewritten file SHALL contain neither line

#### Scenario: Config file contains comments and blank lines
- **WHEN** the user's config file contains comment lines beginning with `#` and blank lines between key-value pairs
- **THEN** the rewritten file SHALL preserve all comments, blank lines, and the ordering of retained keys

#### Scenario: No deprecated keys present
- **WHEN** the config file contains no deprecated keys
- **THEN** no warning is emitted and the config file is NOT rewritten (no unnecessary writes)

### Requirement: CLI deprecated flags are warn-and-ignore
When invoked with a deprecated command-line flag, AutoRaise SHALL print a warning to stderr and continue running; it SHALL NOT exit with a non-zero status. This mirrors the existing silent-ignore policy for unknown `NSArgumentDomain` keys but adds a user-facing warning for known-deprecated keys.

#### Scenario: User passes -delay 2
- **WHEN** AutoRaise is invoked as `AutoRaise -delay 2`
- **THEN** it SHALL print `Warning: delay is deprecated and has been removed in AutoRaise 6.0; ignoring` to stderr and continue with default behavior

#### Scenario: User passes multiple deprecated flags
- **WHEN** AutoRaise is invoked as `AutoRaise -delay 2 -requireMouseStop true -mouseDelta 0.5`
- **THEN** it SHALL print one warning per flag and continue normally

#### Scenario: User passes an unknown flag
- **WHEN** AutoRaise is invoked with a flag that is neither a current supported key nor a known-deprecated key
- **THEN** it SHALL silently ignore it (preserving today's behavior — no new rejection)

## REMOVED Requirements

### Requirement: Multi-tick raise delay
**Reason**: Replaced by event-driven immediate raise. `pollMillis` alone governs responsiveness.
**Migration**: Remove `delay` from configs; AutoRaise will strip it automatically on first run. There is no direct replacement — the closest approximation is a larger `pollMillis` value, which throttles check frequency but does not introduce settle time.

### Requirement: Focus-first behavior (EXPERIMENTAL_FOCUS_FIRST)
**Reason**: Depends on private SLS/CPS APIs; maintained separately in a user fork.
**Migration**: Users who need focus-without-raise must maintain a personal branch with the `FOCUS_FIRST` blocks restored.

### Requirement: requireMouseStop debounce
**Reason**: Incompatible with Hyprland-style instant raise on window change.
**Migration**: None; the new model always raises on hover, mirroring the `requireMouseStop=false` behavior.

### Requirement: mouseDelta jitter filter
**Reason**: Explicit user decision; every mouse movement is treated as significant.
**Migration**: None; remove `mouseDelta` from configs (auto-stripped on first run).

### Requirement: Warp-only mode
**Reason**: The overloaded `delay=0 altTaskSwitcher=true` configuration is replaced by the simpler identity "AutoRaise always raises on hover when running."
**Migration**: Users who want cmd-tab warping without auto-raise must find a different tool or maintain a fork.

### Requirement: Timer-based polling loop
**Reason**: Replaced by the extended `CGEventTap`. Zero-CPU when idle; lower tail latency; simpler control flow.
**Migration**: No user-facing change beyond behavior; internal implementation only.

### Requirement: Tick-skip cooldown after app activation
**Reason**: Replaced by `suppressRaisesUntil` timestamp-based suppression window with a fixed 150ms duration. The prior mechanism (`ignoreTimes=3`, `appWasActivated`) was tied to polling ticks and becomes meaningless in the event-driven model.
**Migration**: None; behavior is preserved with a cleaner mechanism.
