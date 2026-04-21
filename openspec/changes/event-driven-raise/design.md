# Design: Event-Driven Raise

## Architecture

```
┌────────────────────────────────────────────────────────────────┐
│  macOS                                                         │
│    │                                                           │
│    ├─ kCGEventMouseMoved ───────┐                              │
│    ├─ kCGEventKeyDown (cmd-tab) │  (existing keyboard tap)     │
│    ├─ NSSpace changed           │                              │
│    └─ NSApp activated           │                              │
│                                 ▼                              │
│  CGEventTap callback    (listen-only, pass-through)            │
│    │                                                           │
│    if (event is mouseMoved):                                   │
│       if (now - lastCheckTime) < pollMillis: return event      │
│       if (now < suppressRaisesUntil): return event             │
│       lastCheckTime = now                                      │
│       performRaiseCheck(mousePoint)                            │
│    return event  (always pass-through unmodified)              │
│                                                                │
│  Space-change handler (NSNotification, NOT throttled):         │
│       performRaiseCheck(current mouse position)                │
│                                                                │
│  App-activated handler (NSNotification, NOT throttled):        │
│       cursor scale + optional CGWarpMouseCursorPosition        │
│       suppressRaisesUntil = now + 150ms                        │
│       after warp: performRaiseCheck(warped position)           │
│                                                                │
│  performRaiseCheck(CGPoint mousePoint):                        │
│    gen = ++raiseGeneration                                     │
│    abort conditions → return                                   │
│    get_mousewindow → hovered AX element                        │
│    if (hovered != frontmost):                                  │
│       raise(hovered)                                           │
│       dispatch_after(RAISE_RETRY_MS):                          │
│         if (gen == raiseGeneration) raise(hovered)             │
│       dispatch_after(2 * RAISE_RETRY_MS):                      │
│         if (gen == raiseGeneration) raise(hovered)             │
└────────────────────────────────────────────────────────────────┘
```

No polling timer. The run loop is kept alive by:
1. The event tap's `CFRunLoopSource`
2. Existing `NSWorkspace` notification observers (space change, app activated)
3. `dispatch_after` work items when raise retries are scheduled

## Event Tap Configuration

- Placement: `kCGAnnotatedSessionEventTap`
- Options: `kCGEventTapOptionListenOnly`
- Event mask: `CGEventMaskBit(kCGEventMouseMoved)` added to the existing keyboard mask (or a second tap — see "Tap strategy" below)
- Callback **must always return `event` unmodified**. Dropping or mutating the event would break the user's mouse
- `kCGEventTapDisabledByTimeout` and `kCGEventTapDisabledByUserInput` handlers call `CGEventTapEnable(eventTap, true)` — mirroring the existing pattern at AutoRaise.mm:1302-1305

### Tap strategy: extend existing vs add new

The existing keyboard tap (at AutoRaise.mm:1302) could be extended with `kCGEventMouseMoved` in its mask, or we could create a second tap dedicated to mouse events. **Preferred: single extended tap.** One run-loop source, one disabled-handler, simpler lifecycle. The callback dispatches by event type.

## Throttle and Suppression

Two independent guards on `performRaiseCheck` from mouse events:

**Throttle (`pollMillis`):**
- `lastCheckTime` timestamp updated only when a check actually runs
- Mouse events arriving within `pollMillis` of `lastCheckTime` are dropped
- Uses `mach_absolute_time()` converted via `mach_timebase_info`, or `CACurrentMediaTime()` — monotonic, never wall clock
- Space-change and app-activated handlers **bypass** the throttle; they're discrete events, not streams

**Suppression (`suppressRaisesUntil`):**
- Set to `now + SUPPRESS_MS` when an app activation occurs (cmd-tab, etc.)
- `SUPPRESS_MS = 150` — covers the warp → stabilize → new-window-under-cursor window
- Mouse events arriving before `suppressRaisesUntil` are dropped
- Replaces the current `ignoreTimes = 3` logic (AutoRaise.mm:1284, 1291) and `appWasActivated` cooldown (AutoRaise.mm:1048)
- Post-warp explicit `performRaiseCheck` **bypasses** suppression

## Retry Cancellation via Generation Counter

Problem: `dispatch_after` blocks can't be easily cancelled. If the user moves the cursor to another window between the initial raise and a scheduled retry, the stale retry would raise the old window.

Solution: a monotonic `raiseGeneration` counter. Every new `performRaiseCheck` that issues a raise increments it. Each scheduled retry captures `gen` at schedule time and only fires if `gen == raiseGeneration` at execution time.

```
static uint64_t raiseGeneration = 0;

void performRaiseCheck(CGPoint p) {
    // ... abort / filter checks ...
    if (needs_raise) {
        uint64_t gen = ++raiseGeneration;
        do_raise(hovered);
        dispatch_after(RAISE_RETRY_1_MS, main_queue, ^{
            if (gen == raiseGeneration) do_raise(hovered);
        });
        dispatch_after(RAISE_RETRY_2_MS, main_queue, ^{
            if (gen == raiseGeneration) do_raise(hovered);
        });
    }
}
```

## Retry Intervals (Decoupled from pollMillis)

The current code paces retries at `pollMillis` intervals (3 ticks). This worked because `pollMillis >= 20` always gave a meaningful gap. With `pollMillis=1`, three raises in 2ms is functionally one raise.

Retries exist to compensate for **app response time**, not polling cadence. They get decoupled:

- `RAISE_RETRY_1_MS = 50`
- `RAISE_RETRY_2_MS = 100`

Fixed, not configurable. 50ms/100ms matches the empirical window for Finder/Electron to settle — same as today's behavior at the default `pollMillis=50`. No need to introduce a new CLI knob.

## Warp Does Not Emit Mouse Events

`CGWarpMouseCursorPosition` (AutoRaise.mm:964) teleports the cursor without generating a `kCGEventMouseMoved` event — confirmed by Apple's documentation. Today's code doesn't notice or care because the polling loop re-samples position on the next tick. In the event-driven model we'd miss the raise entirely.

Fix: the app-activated handler calls `performRaiseCheck(warpTargetPoint)` explicitly after `CGWarpMouseCursorPosition` returns. This call bypasses suppression (since the suppression window was just opened by this same handler).

## Code Changes

### Removed symbols

```
Globals (AutoRaise.mm ~155-165):
  delayCount, delayTicks, raiseDelayCount, propagateMouseMoved,
  requireMouseStop, mouseDelta, oldPoint, spaceHasChanged,
  appWasActivated, ignoreTimes

Parameter keys (~766-786):
  kDelay, kFocusDelay, kRequireMouseStop, kMouseDelta

FOCUS_FIRST private API decls (AutoRaise.mm:67-78):
  SLPSPostEventRecordTo, _SLPSSetFrontProcessWithOptions,
  _SLPSGetFrontProcess, SLSMainConnectionID
  (CGSSetCursorScale is used outside FOCUS_FIRST — keep)

All #ifdef FOCUS_FIRST / #ifdef EXPERIMENTAL_FOCUS_FIRST blocks

Timer scheduling (AutoRaise.mm:741-746, 1465-1467):
  -onTick: method with recursive afterDelay scheduling
  initial onTick kickoff in main()
```

### New / modified

```
main():
  Extend existing keyboard event-tap mask with CGEventMaskBit(kCGEventMouseMoved)
  (or create a second tap — see Tap strategy above; single tap preferred)

Event-tap callback (existing function, extended):
  if (type == kCGEventMouseMoved):
    if throttle or suppression active: return event
    lastCheckTime = now
    performRaiseCheck(CGEventGetLocation(event))
  (existing keyboard handling unchanged)
  (existing tap-disabled re-enable unchanged)
  return event   ← unconditional pass-through

performRaiseCheck(CGPoint mousePoint):
  - Apply screen-edge corner correction (ported from AutoRaise.mm:1007-1043)
  - All existing abort checks (button, dock, mc, disableKey, stayFocused)
  - All existing filtering (ignoreApps, ignoreTitles, titleEquals, PWA main)
  - get_mousewindow → hovered window
  - AXObserver registration for window-destroyed callback (from AutoRaise.mm:1111-1133)
  - Compare to frontmost focused window
  - If differs: raise + schedule 2 dispatch_after retries via generation counter

Space-change handler (spaceChanged):
  if !ignoreSpaceChanged: performRaiseCheck(current cursor position)

App-activated handler (onAppActivated):
  (existing cursor-scale behavior — unchanged)
  suppressRaisesUntil = now + 150ms
  if warpMouse && activated-via-task-switcher:
    CGWarpMouseCursorPosition(targetPoint)
    performRaiseCheck(targetPoint)  ← explicit post-warp
```

### Config file rewrite

Current config reader is at AutoRaise.mm:823-852 (flat text `key=value`, `#` comments). **No writer exists.** Add one:

```
- (void) rewriteConfig:(NSArray *)removedKeys {
    if (removedKeys.count == 0) return;
    if (!hiddenConfigFilePath) return;

    // Read original file, strip lines matching removed keys (preserving comments
    // and unknown lines), write back to the same path atomically.
    // Use NSString writeToFile:atomically:encoding:error: with atomically=YES.
}
```

The rewrite preserves the user's ordering and comments; it only removes lines whose trimmed key matches a deprecated key.

### CLI unknown-flag handling

NSArgumentDomain silently ignores unknown keys today. For parity, deprecated flags (`-delay`, `-focusDelay`, `-requireMouseStop`, `-mouseDelta`) are **warn-and-ignore**, not strict-reject. After `readConfig`, iterate the `NSArgumentDomain` dict and emit a warning for any key in the deprecated set.

## Removed Behaviors and Migration Path

| Removed | Old config | New behavior |
|---|---|---|
| Multi-tick delay before raise | `delay=3` | Warning + ignored; raise is immediate |
| Raise disabled (warp-only) | `delay=0` | Warning + ignored; AutoRaise always raises |
| Focus-without-raise | `delay=0 focusDelay=1` (FOCUS_FIRST build) | Not supported; fork required |
| Wait for mouse to stop | `requireMouseStop=true` | Warning + ignored; Hyprland-style instant raise |
| Jitter filter | `mouseDelta=0.5` | Warning + ignored; every mouse event counts |

## Risks and Unknowns

**CGEventTap permission surface.** Already requires accessibility permissions (same as today, since the keyboard tap already needs them). No new entitlements.

**AX lookup cost at pollMillis=1.** Worst case: 1000 `get_mousewindow()` calls per second during a flick. Each call is a cross-process AX round trip. CPU burn may be noticeable on heavily-loaded systems. Default stays at 8ms (125/s); pollMillis=1 is opt-in.

**Tap timeout risk.** If `get_mousewindow()` stalls (unresponsive target app), macOS may disable the tap via `kCGEventTapDisabledByTimeout`. The existing handler (mirrored pattern) re-enables it, but raises during the stall are lost. Mitigation: the throttle already bounds the frequency; worst case is one missed raise per stall event.

**Flicker during rapid traversal.** At pollMillis=1, sweeping the cursor across 5 overlapping windows in 50ms triggers 5 distinct raises. Intentional (Hyprland parity); may look jarring on animation-heavy apps.

**Retry interval change.** Switching from `pollMillis`-paced to fixed 50ms/100ms means users who had set `pollMillis=200` (slow machine) will see retries sooner than before. Probably fine — 50ms is still a sensible gap.

**Suppression window tuning.** `SUPPRESS_MS = 150` is a guess. Too short and we raise the wrong window post-cmd-tab; too long and genuine hover-raises after task switch feel sluggish. May need tuning during manual testing.

**Backwards compatibility.** Major version bump (5.6 → 6.0). Users with custom configs see per-key warnings on first run; configs auto-migrated. CLI flag users get runtime warnings (not errors).

**AXObserver for destroyed windows.** The `AXCallback` / `lastDestroyedMouseWindow_id` bookkeeping at AutoRaise.mm:971 and 1102 is orthogonal to the polling model and ports directly into `performRaiseCheck`.

## Alternatives Considered

**Timer-while-active hybrid.** Run a 1ms timer only when mouse is active; stop after N idle ticks. Rejected in favor of pure event-driven — functionally equivalent but carries idle-detection state.

**NSEvent global monitor instead of CGEventTap.** Simpler API but higher latency and cannot re-enable after timeout the same way. Rejected.

**Keep `requireMouseStop` as a toggle.** Would preserve the non-Hyprland mode for users who prefer it. Rejected per explicit request.

**Preserve FOCUS_FIRST behind a runtime config flag.** Would require keeping all the private-API dependencies compiled in. Rejected; feature stays in a user-maintained fork.

**Configurable retry interval.** Considered `-raiseRetryMillis` CLI knob. Rejected — 50/100ms is empirically good and adding a knob bloats the interface.

**Strict CLI rejection of removed flags.** Rejected — current code silently ignores unknowns, so rejection would be a separate behavior change. Warn-and-ignore is symmetric with config handling.
