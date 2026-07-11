## High-level cordnim application framework.
##
## Import narrower modules such as `cordnim/raw`, `cordnim/rest`, or
## `cordnim/gateway` when protocol-level control is required. The main module
## exports the application-facing types without merging colliding raw wire
## names into the same namespace.

import cordnim/[app, application_manifest, commands, components, core,
  interactions, runtime]

export app, application_manifest, commands, components, core, interactions,
  runtime

when isMainModule:
  import cordnim/cli

  quit(runCli())
