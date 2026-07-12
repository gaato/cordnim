## High-level Cordnim application surface.
##
## This module exports application composition, command declarations,
## component builders, core types, build identity, and the HTTP interaction
## runtime factory.
##
## Cordnim 0.1.0 is a preview. Public APIs may change before a stable release.
## Choose imports from the transport boundary your application owns:
##
## * Import `cordnim` for commands, components, and verified HTTP interactions.
## * Import `cordnim/bot` as well for a complete Gateway bot with owned REST,
##   typed events, interactions, shards, and shutdown.
## * A hybrid application uses HTTP interaction ingress plus Gateway event
##   subscriptions. It attaches both runtimes to one `DiscordApp`.
##
## `cordnim/api` contains semantic REST operations, `cordnim/models` contains
## lossless resource values, and `cordnim/testing` supplies deterministic
## transports and fixtures. Import `cordnim/interactions`, `cordnim/raw`,
## `cordnim/rest`, or `cordnim/gateway` for lower-level control.

import cordnim/[app, application_manifest, build_info, command_policies,
  commands, components, core, events]
from cordnim/interactions/http_runtime import InteractionHttpRuntime,
  localAddress, newInteractionHttpRuntime
from cordnim/interactions/sodium_verifier import sodiumVerificationConfig,
  sodiumVerifierEnabled
from cordnim/interactions/verification import VerificationConfig,
  parseEd25519PublicKey

export app, application_manifest, build_info, command_policies, commands,
  components, core, events
export InteractionHttpRuntime, VerificationConfig, localAddress,
  newInteractionHttpRuntime, parseEd25519PublicKey, sodiumVerificationConfig,
  sodiumVerifierEnabled

when isMainModule:
  import cordnim/cli

  quit(runCli())
