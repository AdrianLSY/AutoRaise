# Tasks: Event-Driven Raise

## Implementation

- [x] 1. Extract raise logic from `onTick()` into `void performRaiseCheck(CGPoint mousePoint)`. Port: screen-edge correction, abort conditions (button/dock/mc/disableKey/stayFocused), ignore filters (ignoreApps/ignoreTitles/titleEquals/PWA-main), `get_mousewindow`, `AXObserver` destroyed-window registration, focus-window comparison, raise issuance. Drop: `delayTicks`/`delayCount` logic, `mouseDelta` jitter filter, `requireMouseStop` branch, `propagateMouseMoved` handling, `spaceHasChanged` in-flight flag, `appWasActivated` tick-skip, `ignoreTimes` countdown.
- [x] 2. Add module-level state for the new model: `static double lastCheckTime = 0`, `static double suppressRaisesUntil = 0`, `static uint64_t raiseGeneration = 0`. Using `[[NSProcessInfo processInfo] systemUptime]` (monotonic) via a `currentTimeMillis()` helper.
- [x] 3. Extend the existing event tap's event mask with `CGEventMaskBit(kCGEventMouseMoved)`. Verified tap creation uses `kCGEventTapOptionListenOnly`.
- [x] 4. In the existing event-tap callback, added a mouse-moved branch before the keyboard branch: checks throttle (`now - lastCheckTime < pollMillis` → return event), checks suppression (`now < suppressRaisesUntil` → return event), otherwise updates `lastCheckTime` and calls `performRaiseCheck`. **Always returns `event` unmodified at end of callback.** Keyboard and tap-disabled branches intact.
- [x] 5. In `performRaiseCheck`, replaced the `raiseTimes = 3` in-tick decrement with: increment `raiseGeneration` to a local `gen`, issue initial raise, schedule two `dispatch_after` blocks at `RAISE_RETRY_1_MS` (50) and `RAISE_RETRY_2_MS` (100) that each re-issue the raise only if `gen == raiseGeneration`. Constants defined near top of file.
- [x] 6. Space-change handler (`spaceChanged`) now calls `performRaiseCheck(current cursor position)` directly when `!ignoreSpaceChanged`. `spaceHasChanged` flag removed.
- [x] 7. App-activated handler: keeps existing cursor-scale path; sets `suppressRaisesUntil = now + 150ms` on entry; calls `performRaiseCheck(warpTarget)` immediately after `CGWarpMouseCursorPosition`. `appWasActivated` and `ignoreTimes` removed.
- [x] 8. Removed globals: `delayCount`, `delayTicks`, `raiseDelayCount`, `propagateMouseMoved`, `requireMouseStop`, `mouseDelta`, `spaceHasChanged`, `appWasActivated`, `ignoreTimes`, `oldCorrectedPoint`. `oldPoint` kept (still used by `appActivated` movement heuristic and `performRaiseCheck` corner correction).
- [x] 9. Removed parameter keys and declarations: `kDelay`, `kFocusDelay`, `kRequireMouseStop`, `kMouseDelta`. Help output updated.
- [x] 10. Deleted all `#ifdef FOCUS_FIRST` / `#ifdef EXPERIMENTAL_FOCUS_FIRST` blocks.
- [x] 11. Deleted FOCUS_FIRST-only private-API declarations and helper functions (`SLPSPostEventRecordTo`, `_SLPSSetFrontProcessWithOptions`, `window_manager_make_key_window`, `window_manager_focus_window_without_raise`). Kept `CGSSetCursorScale` and related decls.
- [x] 12. Removed NSTimer-based `-onTick:` method and its kickoff. No timer scheduling remains.
- [x] 13. Removed the `altTaskSwitcher && !delayCount` short-circuit. Cmd-tab warping runs alongside raise unconditionally.
- [x] 14. Changed `pollMillis` validation: clamp to 8 when value `< 1`; no absent-value default (read from config or NSArgumentDomain then clamped).
- [x] 15. Added config file writer `rewriteConfigStrippingDeprecatedKeys`. Reads the current config file, strips lines whose trimmed key matches any deprecated key, preserves comments and other lines, writes back atomically. Skips write if nothing changed.
- [x] 16. Added `warnAndStripDeprecated` method that iterates `deprecatedKeys` (`delay`, `focusDelay`, `requireMouseStop`, `mouseDelta`) and emits `fprintf(stderr, "Warning: %s is deprecated and has been removed in AutoRaise 6.0; ignoring\n", ...)` for each present, then removes from parameters dict. Deprecated keys are loaded from both CLI (NSArgumentDomain) and config file so warnings fire in both cases.
- [x] 17. Updated `printf` help block: removed deprecated flags; updated `-pollMillis` to `<1, 2, ..., 8, ..., 50, ...>  (default 8)`.
- [x] 18. Updated `Started with:` block: dropped delay/focusDelay/requireMouseStop/mouseDelta lines; kept pollMillis, altTaskSwitcher, warp, scale, ignoreSpaceChanged, ignoreApps, ignoreTitles, stayFocusedBundleIds, disableKey, invertDisableKey, invertIgnoreApps, verbose.
- [x] 19. `AUTORAISE_VERSION` updated to `"6.0"`.
- [x] 20. Updated `README.md`:
  - [x] Removed `delay`, `focusDelay`, `requireMouseStop`, `mouseDelta` parameter documentation
  - [x] Removed `EXPERIMENTAL_FOCUS_FIRST` compile-flag documentation
  - [x] Updated the example command line
  - [x] Updated the example config file
  - [x] Updated the "Started with" output example and usage block
  - [x] Added an "Upgrading from 5.x" migration section

## Manual Verification

- [ ] 21. Build succeeds without `FOCUS_FIRST` define (no #ifdef compile errors).
- [ ] 22. `AutoRaise -pollMillis 1` launches and hovering between two overlapping windows at any mouse speed produces an immediate raise.
- [ ] 23. Dragging a window by its title bar does not trigger raises on other windows the cursor passes over (button-held abort).
- [ ] 24. Cmd-tab with `altTaskSwitcher=true` and `warpX=0.5 warpY=0.5` warps the cursor to the activated window's center, and that window gets a raise check (if it wasn't already frontmost). No stray raise of the under-cursor window during the warp transition.
- [ ] 25. Switching Spaces via a gesture triggers a raise for the now-hovered window (when `ignoreSpaceChanged=false`).
- [ ] 26. An app in `ignoreApps` does not get raised on hover; a window in `stayFocusedBundleIds` prevents raises while frontmost; `disableKey=control` held suppresses raise.
- [ ] 27. Launch with an old config containing `delay=1 requireMouseStop=true mouseDelta=0.1`: each key produces a warning on stderr; the config file is rewritten with those keys removed; user comments in the config are preserved; no keys are added or reordered unnecessarily.
- [ ] 28. Launch with CLI `-delay 2 -focusDelay 1`: both produce warnings on stderr; AutoRaise continues normally with defaults.
- [ ] 29. Flick the cursor across 5 overlapping windows in under 100ms at `pollMillis=8`: observe each window getting a raise as the cursor enters it, with no crashes or event-tap disables.
- [ ] 30. Leave AutoRaise running idle (no mouse movement) for 60 seconds: `top` or Activity Monitor shows near-zero CPU usage.
- [ ] 31. Intentionally hover over an unresponsive app to force an AX-call stall: verify the tap re-enables after `kCGEventTapDisabledByTimeout` (look for `Got event tap disabled event, re-enabling...` in verbose mode).
