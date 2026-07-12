## Read-only semantic access to Discord application resources.

import chronos

import cordnim/api/internal/execute
import cordnim/api/options
import cordnim/core/ids
import cordnim/models/oauth
import cordnim/raw/request as raw_request
import cordnim/raw/route
import cordnim/raw/routes/applications as application_routes
import cordnim/rest/chronos_driver
import cordnim/rest/request

proc fetchCurrentApplication*(client: ChronosRestClient;
                              options = initApiCallOptions()):
                              Future[PrivateApplication] {.async.} =
  ## Fetches the application owned by the current bot credential.
  let raw = raw_request.initRawRequest(application_routes.getMyApplication)
  return await client.executeJson(raw, decodePrivateApplication,
    auth = darBot, meta = options.requestMeta(idSafe))

proc fetchApplication*(client: ChronosRestClient;
                       applicationId: ApplicationId;
                       options = initApiCallOptions()):
                       Future[PrivateApplication] {.async.} =
  ## Fetches one application available to the current credential.
  let raw = raw_request.initRawRequest(application_routes.getApplication, [
    initRawParameter("application_id", $applicationId),
  ])
  return await client.executeJson(raw, decodePrivateApplication,
    auth = darBot, meta = options.requestMeta(idSafe))
