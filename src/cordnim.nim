## High-level Cordnim application surface.
##
## This module exports application composition, command declarations,
## component builders, core types, build identity, and the HTTP interaction
## runtime factory.
## Import `cordnim/interactions`, `cordnim/raw`, `cordnim/rest`, or
## `cordnim/gateway` explicitly for lower-level protocol and transport control.

import cordnim/[app, application_manifest, build_info, commands, components,
  core]
from cordnim/interactions/http_runtime import InteractionHttpRuntime,
  localAddress, newInteractionHttpRuntime
from cordnim/interactions/sodium_verifier import sodiumVerificationConfig,
  sodiumVerifierEnabled
from cordnim/interactions/verification import VerificationConfig,
  parseEd25519PublicKey

export app, application_manifest, build_info, commands, components, core
export InteractionHttpRuntime, VerificationConfig, localAddress,
  newInteractionHttpRuntime, parseEd25519PublicKey, sodiumVerificationConfig,
  sodiumVerifierEnabled

when isMainModule:
  import cordnim/cli

  quit(runCli())
