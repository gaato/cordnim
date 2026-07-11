## Deterministic monotonic clock for command and deadline tests.

type
  FakeClock* = object ## Manually advanced monotonic millisecond clock.
    nowMs*: int64     ## Current test time in milliseconds.

func initFakeClock*(nowMs = 0'i64): FakeClock =
  ## Creates a fake clock at `nowMs`.
  FakeClock(nowMs: nowMs)

proc advance*(clock: var FakeClock, milliseconds: int64) =
  ## Advances the clock; negative durations are rejected.
  if milliseconds < 0:
    raise newException(ValueError, "fake clock cannot move backwards")
  clock.nowMs += milliseconds
