## Legacy components, Components V2, typed forms, and signed routes.
##
## Legacy and V2 message drafts are distinct types. Modal derivation produces a
## validated schema and decoder, while typed route codecs keep restart-safe
## `custom_id` state separate from process-local collectors.

import cordnim/components/[bearssl_signer, dsl, forms, model, routes,
  serialization, typed_routes, validation]

export bearssl_signer, dsl, forms, model, routes, serialization, typed_routes,
  validation

runnableExamples:
  let message = v2Message:
    container:
      text "Deployment ready"
  doAssert message.validate().valid
