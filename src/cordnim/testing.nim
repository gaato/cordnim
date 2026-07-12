## In-process application harnesses and a manually advanced monotonic clock.
##
## `TestDiscordApp` dispatches command invocations through the real application
## code and records inputs and results without opening sockets. `FakeClock`
## gives deadline and cache tests an integer clock that can move forward under
## test control. Production entry modules do not import these helpers.

import cordnim/testing/all

export all

runnableExamples:
  var clock = initFakeClock(1_000)
  clock.advance(250)
  doAssert clock.nowMs == 1_250
