## Public in-process application harness and fake-clock helpers.
##
## The harness records command invocations and results. The fake clock supports
## deterministic deadline and cache tests without reading wall-clock time.

import ./[app_harness, fake_clock]

export app_harness, fake_clock
