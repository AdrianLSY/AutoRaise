# Proposal: Event-Driven Raise

## Problem

AutoRaise uses a timer loop with a hardcoded minimum poll interval of 20ms.
Combined with delay-tick logic (`delay`, `focusDelay`) and `requireMouseStop`,
this introduces perceptible latency between crossing a window boundary and
seeing the raise. Users accustomed to Hyprland-style follow-mouse compositors
expect raises to fire on every window crossing, with no settle time and no
multi-tick countdown.

## Solution

Replace the timer-polled architecture with a pure event-driven one. The existing
`CGEventTap` (currently listening only for keyboard events) is extended to also
observe `kCGEventMouseMoved`. The callback runs as listen-only, passes every
event through unmodified, and for mouse moves performs a throttled check: drop
if less than `pollMillis` since the last accepted event, otherwise look up the
hovered window and raise if it differs from the frontmost.

The delay/focusDelay/requireMouseStop/mouseDelta logic is removed entirely.
`pollMillis` (default 8, minimum 1) is the only responsiveness knob, functioning
as a max-AX-lookup-rate throttle.

Retries for apps that don't respect the first raise are scheduled via
`dispatch_after` with a generation-counter cancellation mechanism, so stale
retries don't fire for windows the user has already moved away from. Retry
timing is decoupled from `pollMillis` and fixed at 50ms/100ms — the gap exists
to cover app response time, not polling cadence.

## Scope

- Extend the existing event tap with `kCGEventMouseMoved`; the callback dispatches by type
- Replace `onTick()` with `performRaiseCheck(CGPoint)` callable from the tap callback, the space-change handler, and post-warp in the app-activated handler
- Remove `delay`, `focusDelay`, `requireMouseStop`, `mouseDelta` CLI/config options and their internal state
- Remove `FOCUS_FIRST` / `EXPERIMENTAL_FOCUS_FIRST` code paths entirely (all `#ifdef` blocks and FOCUS_FIRST-only private-API decls)
- Drop `delay=0` "warp-only" mode; AutoRaise always raises on hover when running
- Lower `pollMillis` minimum from 20 to 1; change default from 50 to 8
- Add a config file writer (none exists today); rewrite on startup to strip deprecated keys while preserving user comments and ordering
- Warn-and-ignore deprecated CLI flags (matching the existing silent-ignore policy for unknown flags, but with a warning)
- Bump version to 6.0

## Out of Scope

- Cmd-tab warping behavior (`altTaskSwitcher`, `warpX`/`warpY`, `scale`) — unchanged, but the warp path gains an explicit post-warp `performRaiseCheck` call since `CGWarpMouseCursorPosition` doesn't emit mouse-moved events
- Space-change handling — preserved; now calls `performRaiseCheck` directly, bypassing throttle and suppression
- `ignoreApps`, `ignoreTitles`, `stayFocusedBundleIds`, `disableKey`, `invertDisableKey`, `invertIgnoreApps`, `ignoreSpaceChanged` — unchanged
- Multi-raise retry count (3) — preserved; scheduling mechanism changes

## Design Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Input source | Extend existing `CGEventTap` with `kCGEventMouseMoved` | One tap, one run-loop source, one disabled-re-enable handler; simpler lifecycle than a second tap |
| Architecture | Pure event-driven, no timer | Zero CPU when mouse idle; `lastCheckTime` throttle naturally rate-limits AX calls |
| Event handling | `kCGEventTapOptionListenOnly`; callback always returns `event` unmodified | Prevents dropping mouse events from the user's input stream — a correctness must |
| Raise semantics | Hyprland-style: raise on every window change | Matches user expectation; no settle time, no debounce |
| Default `pollMillis` | 8ms (~120 Hz) | Matches typical display refresh; imperceptible latency with negligible CPU |
| Minimum `pollMillis` | 1ms | Effectively unthrottled for power users; opt-in CPU cost |
| Drop `FOCUS_FIRST` | Remove the compile flag entirely | Experimental feature with private-API dependencies; user maintains a personal fork |
| Drop warp-only mode | Yes | `delay=0` was an overloaded semantic; AutoRaise's identity is "raise on hover" |
| `mouseDelta` removed | Yes | User explicitly does not want jitter filtering |
| `requireMouseStop` removed | Yes | Fundamentally incompatible with Hyprland-style raise |
| Retry mechanism | `dispatch_after` + monotonic generation counter | Stale retries self-cancel when the user's cursor moves to a different window |
| Retry intervals | Fixed 50ms and 100ms, decoupled from `pollMillis` | Retries exist to cover app response time, not polling cadence; fixed values match today's default behavior |
| Post-activation suppression | 150ms suppression window after app activation | Replaces `ignoreTimes=3` and `appWasActivated` tick-skip; prevents raising the wrong window during warp settle |
| Post-warp raise | Explicit `performRaiseCheck(warpTarget)` after `CGWarpMouseCursorPosition` | `CGWarpMouseCursorPosition` doesn't emit mouse-moved events, so without this we'd miss the raise |
| Config migration | Warn-and-ignore deprecated keys in CLI and file; rewrite file to strip deprecated lines | Preserves user's comments and ordering; auto-cleans config over time |
| Version bump | 6.0 | Breaking config/flag changes justify a major bump |

## References

- `AutoRaise.mm:977` — current `onTick()` implementation
- `AutoRaise.mm:865` — hardcoded `pollMillis` floor (to be lowered)
- `AutoRaise.mm:741-746` — current NSTimer scheduling (to be removed)
- `AutoRaise.mm:1302-1305` — existing tap-disabled re-enable pattern (to be mirrored)
- `AutoRaise.mm:67-78` — FOCUS_FIRST private-API decls (to be removed)
- `AutoRaise.mm:823-852` — existing config reader (writer to be added)
- `AutoRaise.mm:964` — `CGWarpMouseCursorPosition` call (gains a companion `performRaiseCheck`)
- `AutoRaise.mm:1284, 1291, 1048` — `ignoreTimes`/`appWasActivated` cooldown (replaced by `suppressRaisesUntil`)
- README.md lines 40, 46, 63, 196 — FOCUS_FIRST documentation (to be removed)
