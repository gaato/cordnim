import std/assertions

import chronos

import cordnim/core/secrets
import cordnim/rest/http_transport

let token = initSecret[BotToken]("test-token")
let bearer = initSecret[OAuthBearerToken]("test-bearer")

block https_is_the_public_transport_default:
  let transport = newDiscordHttpTransport(token)
  waitFor transport.close()

  let oauthTransport = newDiscordOAuthHttpTransport(bearer)
  waitFor oauthTransport.close()

  let publicTransport = newDiscordPublicHttpTransport()
  waitFor publicTransport.close()

block loopback_http_is_available_for_deterministic_tests:
  let transport = newWebhookHttpTransport("http://127.0.0.1:8080/api/v10")
  waitFor transport.close()

block cleartext_external_origins_are_rejected:
  doAssertRaises ValueError:
    discard newDiscordHttpTransport(token, "http://discord.example/api/v10")
  doAssertRaises ValueError:
    discard newDiscordOAuthHttpTransport(
      bearer, "http://discord.example/api/v10")

block credential_and_query_bearing_origins_are_rejected:
  doAssertRaises ValueError:
    discard newWebhookHttpTransport("https://user@example.com/api/v10")
  doAssertRaises ValueError:
    discard newWebhookHttpTransport("https://example.com/api/v10?token=secret")

block empty_credentials_are_rejected_by_kind:
  doAssertRaises ValueError:
    discard newDiscordOAuthHttpTransport(initSecret[OAuthBearerToken](""))
