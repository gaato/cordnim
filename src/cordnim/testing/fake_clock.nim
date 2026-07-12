## Deterministic monotonic clock for command and deadline tests.

type
  FakeClock* = object ## Manually advanced monotonic millisecond clock.
    nowMs*: int64 ## Current test time in milliseconds.

  ManualClock* = FakeClock ## Preferred name for the manually advanced clock.
    ## `FakeClock` remains a source-compatible alias for existing tests; both
    ## names refer to the same value type and share all operations.

proc initFakeClock*(nowMs = 0'i64): FakeClock =
  ## Creates a fake clock at `nowMs`.
  if nowMs < 0:
    raise newException(ValueError,
      "fake clock must start at a non-negative monotonic instant")
  FakeClock(nowMs: nowMs)

proc initManualClock*(nowMs = 0'i64): ManualClock =
  ## Creates a manually advanced clock at `nowMs` (alias of `initFakeClock`).
  initFakeClock(nowMs)

proc advance*(clock: var FakeClock, milliseconds: int64) =
  ## Advances the clock; negative durations are rejected.
  if milliseconds < 0:
    raise newException(ValueError, "fake clock cannot move backwards")
  if clock.nowMs > high(int64) - milliseconds:
    raise newException(ValueError, "fake clock advance would overflow")
  clock.nowMs += milliseconds

func nowMillis*(clock: FakeClock): int64 =
  ## Returns the current test time in milliseconds.
  clock.nowMs
