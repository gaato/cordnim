## Semantic wrappers for Discord's OAuth resource endpoints.
##
## These operations inspect an existing authorization. Token exchange, refresh,
## and revocation are not part of Discord's pinned stable API snapshot.

import chronos

import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/models/oauth
import cordnim/raw/request as raw_request
import cordnim/raw/routes/oauth2 as oauth_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

proc fetchCurrentAuthorization*(client: ChronosRestClient;
                                options = initApiCallOptions()):
                                Future[OAuthAuthorization] {.async.} =
  ## Returns metadata for the credential configured on the REST transport.
  let raw = raw_request.initRawRequest(oauth_routes.getMyOauth2Authorization)
  return await client.executeJson(raw, decodeOAuthAuthorization,
    options.requestMeta(idSafe))

proc fetchCurrentOAuthApplication*(client: ChronosRestClient;
                                   options = initApiCallOptions()):
                                   Future[PrivateApplication] {.async.} =
  ## Returns the application associated with the current OAuth authorization.
  let raw = raw_request.initRawRequest(oauth_routes.getMyOauth2Application)
  return await client.executeJson(raw, decodePrivateApplication,
    options.requestMeta(idSafe))

proc fetchOAuthPublicKeys*(client: ChronosRestClient;
                           options = initApiCallOptions()):
                           Future[OAuthPublicKeys] {.async.} =
  ## Fetches Discord's public JSON Web Key set.
  let raw = raw_request.initRawRequest(oauth_routes.getPublicKeys)
  return await client.executeJson(raw, decodeOAuthPublicKeys,
    options.requestMeta(idSafe))

proc fetchOpenIdIdentity*(client: ChronosRestClient;
                          options = initApiCallOptions()):
                          Future[OpenIdIdentity] {.async.} =
  ## Fetches OpenID Connect claims for the current bearer credential.
  let raw = raw_request.initRawRequest(oauth_routes.getOpenidConnectUserinfo)
  return await client.executeJson(raw, decodeOpenIdIdentity,
    options.requestMeta(idSafe))
