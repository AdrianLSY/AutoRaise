# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

AutoRaise is a macOS utility implementing focus-follows-mouse with raise-on-hover. It is a single-file Objective-C++ program targeting the macOS Accessibility API. The main loop is **pure event-driven** (no timer), driven by a listen-only `CGEventTap`.

## Build & Run

The `Makefile` targets:

- `make` — build both binaries: `AutoRaise` (CLI) and `AutoRaise.app` (reads a config file, no GUI).
- `make clean` — remove build outputs.
- `make install` — copy `AutoRaise.app` into `/Applications/`.
- `make build` — clean, then build with `-DOLD_ACTIVATION_METHOD -DEXPERIMENTAL_FOCUS_FIRST`.
- `make run` / `make debug` — `make build` then run with `-focusDelay 1` (and `-verbose 1` for `debug`).
- `make update` — `build` + `install`.

**Note:** the Makefile's `build`/`run`/`debug` targets still pass `-DEXPERIMENTAL_FOCUS_FIRST` and `-focusDelay 1`. Both are inert now: `EXPERIMENTAL_FOCUS_FIRST` is a no-op (all `#ifdef FOCUS_FIRST` blocks and SkyLight private-API decls have been removed), and `-focusDelay` is on the deprecated-flags list and emits `Warning: focusDelay is deprecated and has been removed in AutoRaise 6.0; ignoring`. The targets still work; they just produce the warning on every `make run`.

Remaining compile-time flags:

- `OLD_ACTIVATION_METHOD` — use the deprecated Carbon `SetFrontProcessWithOptions` activation path. Needed for some non-native (GTK/SDL/wine) apps; emits a deprecation warning.
- `ALTERNATIVE_TASK_SWITCHER` — changes default for `altTaskSwitcher` to `true`; affects mouse warp behavior with non-default task switchers.

`SKYLIGHT_AVAILABLE` auto-detection in the Makefile still runs but nothing links against SkyLight anymore (only `CGSSetCursorScale` from the regular Core Graphics headers is used).

There is no test suite. Behavior is verified manually by running the binary and exercising window-focus scenarios; `-verbose true` prints a per-event log that's the primary debugging tool.

## Architecture

Everything lives in [AutoRaise.mm](AutoRaise.mm). Banner-comment sections:

1. **Globals & constants** (top) — tunables like `WINDOW_CORRECTION` (the 3px transparent border Monterey+ adds around windows), `MENUBAR_CORRECTION`, `ACTIVATE_DELAY_MS`, cursor-scale timings, plus `RAISE_RETRY_1_MS = 50`, `RAISE_RETRY_2_MS = 100`, `SUPPRESS_MS = 150`. Core event-driven state: `lastCheckTime`, `suppressRaisesUntil`, `raiseGeneration` — all driven by the `currentTimeMillis()` helper wrapping `[NSProcessInfo processInfo].systemUptime` (monotonic, never wall clock). Also the app/title denylists (`mainWindowAppsWithoutTitle`, `pwas`, `AppsRaisingOnFocus`, etc.).

2. **Helper methods** — `get_mousewindow` → `get_raisable_window` is the recursive AX-element walker that, given a point, finds the `AXWindow`/`AXSheet`/`AXDrawer` that should be raised. `fallback` uses `CGWindowListCopyWindowInfo` when the AX API can't resolve the element. `is_main_window`, `is_full_screen`, `is_desktop_window`, `is_pwa`, `contained_within`, `titleEquals` are the predicates that decide whether a candidate window is actually raiseable.

3. **`MDWorkspaceWatcher`** — subscribes to `NSWorkspaceActiveSpaceDidChangeNotification` and (when warp is enabled) `NSWorkspaceDidActivateApplicationNotification`. **No timer.** The only scheduled work is the delayed cursor-scale (grow-then-shrink) animation after warp.

4. **`ConfigClass`** — reads from CLI args (`NSUserDefaults`/`NSArgumentDomain` when `argc > 1`) or from `~/.AutoRaise` / `~/.config/AutoRaise/config` (flat `key=value` dotfile). Migration path for removed 5.x keys: `warnAndStripDeprecated` emits one `Warning: <key> is deprecated…` per removed key and removes it from the in-memory parameters dict; `rewriteConfigStrippingDeprecatedKeys` atomically rewrites the config file with deprecated lines removed, preserving comments and retained-key ordering. Parameter keys are declared as `NSString * const k…` constants and enumerated in `parametersDictionary`; add new parameters in both places plus a default in `validateParameters`. The deprecated set (`delay`, `focusDelay`, `requireMouseStop`, `mouseDelta`) lives alongside these.

5. **"where it all happens"** — four functions:
   - `spaceChanged()` — called on space change; calls `performRaiseCheck(current cursor)` directly, bypassing throttle and suppression (unless `ignoreSpaceChanged` is true).
   - `appActivated()` — handles cmd-tab warp. Sets `suppressRaisesUntil = now + SUPPRESS_MS`, does `CGWarpMouseCursorPosition`, then explicitly calls `performRaiseCheck(warpTarget)` because warp does not emit `kCGEventMouseMoved`.
   - `AXCallback()` — fires on `kAXUIElementDestroyedNotification` for the currently-hovered window.
   - **`performRaiseCheck(CGPoint mousePoint)`** — the central raise routine. Applies screen-edge/menubar correction, runs all abort checks (button held, dock/mc active, `disableKey`, `stayFocusedBundleIds`, `ignoreApps`, `ignoreTitles`), calls `get_mousewindow`, registers the `AXObserver` for destroyed-window callbacks, compares hovered vs. frontmost. If they differ: increments `raiseGeneration` to a local `gen`, calls `raiseAndActivate`, and schedules two `dispatch_after` retries at 50ms and 100ms that each re-raise only if `gen == raiseGeneration` at execution time. This generation-counter gate is the cancellation mechanism for stale retries when the cursor has moved on.

6. **`eventTapHandler` + `main`** — one extended `CGEventTap` observes keyboard (`kCGEventKeyDown`, `kCGEventFlagsChanged`) **and** `kCGEventMouseMoved`. The handler dispatches by type: mouse-moved events hit the throttle (`now - lastCheckTime < pollMillis` → drop), then the suppression gate (`now < suppressRaisesUntil` → drop), then call `performRaiseCheck`. **The handler must always return `event` unmodified** — the tap is `kCGEventTapOptionListenOnly`; dropping or mutating events would break the user's mouse. Keyboard handling detects cmd-tab / cmd-grave and opens the suppression window; tap-disabled events trigger a `CGEventTapEnable(tap, true)` recovery.

### Mental model for changes

- **Three entry points to `performRaiseCheck`**: the mouse-moved tap branch (throttled + suppressed), `spaceChanged()` (direct, unconditional), and post-warp in `appActivated()` (direct, bypasses suppression it just opened). When editing `performRaiseCheck`, remember all three callers.
- **Generation counter discipline**: every new raise issuance increments `raiseGeneration`. Scheduled retries capture `gen` at schedule time and gate on `gen == raiseGeneration` at execution. Do not increment on "no raise needed" paths or the cancellation semantics break.
- **Never wall clock**: all timing uses `currentTimeMillis()` (monotonic via `systemUptime`). Adding a new deadline? Use the same helper.
- **Coordinate system gotcha**: screen Y is flipped between AppKit (origin bottom-left) and Core Graphics (origin top-left). `findDesktopOrigin`, `findScreen`, and the correction logic in `performRaiseCheck` all juggle this — follow existing patterns rather than inventing new ones.
- **CF/AX memory**: the code uses manual `CFRelease` throughout (the file is compiled with `-fobjc-arc` but ARC doesn't cover Core Foundation types). New AX/CF code must follow Create/Get rule discipline; leaks here will accumulate across every event.
- **Deprecated keys are load-bearing**: `warnAndStripDeprecated` and the config rewriter form the 5.x → 6.0 migration path. Adding a new removed key requires a parameter-key constant (to be recognized in parsing) plus adding it to the deprecated list.

## Configuration

Runtime configuration is documented in [README.md](README.md). Summary:

- CLI form: `./AutoRaise -pollMillis 8 -warpX 0.5 …` (flags map 1:1 to the `k…` constants).
- `AutoRaise.app` has no CLI; it reads `~/.AutoRaise` or `~/.config/AutoRaise/config`. The bundle is marked `LSUIElement` in [Info.plist](Info.plist), so it runs background-only with no Dock icon — stop via Activity Monitor or the AppleScript toggle in the README.
- `pollMillis`: minimum 1, default 8 (≈120 Hz throttle). There is no other responsiveness knob.
- Removed in 6.0, still warn-and-ignored for migration: `delay`, `focusDelay`, `requireMouseStop`, `mouseDelta`.

## Release / versioning

Bumping the version requires three coordinated edits:

- `AUTORAISE_VERSION` macro in [AutoRaise.mm](AutoRaise.mm)
- `CFBundleShortVersionString` in [Info.plist](Info.plist)
- Copyright strings (`AutoRaise.mm` header and `Info.plist`'s `CFBundleGetInfoString`) if the year changed

`AutoRaise.dmg` is a checked-in binary artifact shipped as the release download; rebuild it when cutting a release.
