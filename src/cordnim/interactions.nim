## Interaction ingress, context, verification, and response state.
##
## `InteractionDispatcher` is the transport-independent entry point: it
## classifies an interaction and routes commands, autocomplete, message
## components, and modal submissions through one shared response model, behind a
## single HTTP adapter and a single Gateway adapter.

import cordnim/interactions/[auto_defer, autocomplete, capability,
  component_router, context, dispatch_core, dispatcher, exchange, http_runtime,
  http_server, modal_router, responder, response_codec, router,
  sodium_verifier, verification, webhook_completion]

export auto_defer, autocomplete, capability, component_router, context,
  dispatch_core, dispatcher, exchange, http_runtime, http_server, modal_router,
  responder, response_codec, router, sodium_verifier, verification,
  webhook_completion

runnableExamples:
  import std/json

  doAssert classify(%*{"type": 1}) == icPing
  doAssert pingResponse().body == %*{"type": 1}
