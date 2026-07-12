## Typed application-command declarations, schemas, manifests, and dispatch.
##
## Macros compile procedures into `CommandSpec` values and handler adapters.
## Builders cover dynamic and nested command schemas. Neither path performs
## Discord I/O; synchronization is an operator action.

import chronos
import cordnim/commands/[macros, manifest, pragmas, spec]

export chronos, macros, manifest, pragmas
export spec except dispatchWithServices

runnableExamples:
  let ping = initChatInputCommand("ping", "Measure command dispatch")
  doAssert ping.kind == ckChatInput
  doAssert ping.options.len == 0
