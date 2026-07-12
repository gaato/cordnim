## Structured ownership for Chronos child tasks.
##
## `TaskScope` retains already-created child futures under one event-loop owner.
## Closing a scope rejects and cancels new children. `cancelAndJoin` waits for
## every retained child before it returns, so shutdown does not leave detached
## work behind.

import cordnim/runtime/task_scope

export task_scope
