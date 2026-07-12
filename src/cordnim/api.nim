## Handwritten semantic Discord REST APIs.
##
## Generated descriptors remain available under `cordnim/raw`; this facade
## returns stable value models and uses the supervised rate-aware REST client.
## It does not create or own a client. A Gateway application borrows the running
## client from `bot.rest`; custom compositions construct and supervise a
## `ChronosRestClient`. Operations return `Future[T]` and accept
## `ApiCallOptions` for deadlines, priority, cancellation, and audit reasons.
## Use `cordnim/raw` when no semantic operation covers an endpoint.

runnableExamples:
  import chronos
  import cordnim/models/oauth
  import cordnim/rest/chronos_driver

  proc fetchOwner(client: ChronosRestClient): Future[PrivateApplication] {.
      async.} =
    return await client.fetchCurrentApplication(initApiCallOptions())

import cordnim/api/[applications, channels, fields, gateway_bootstrap, guilds,
  members, messages, monetization, oauth2, options, threads, webhooks]

export applications, channels, fields, gateway_bootstrap, guilds, members,
  messages, monetization, oauth2, options, threads, webhooks
