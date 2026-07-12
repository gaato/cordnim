## Lifecycle adapter from `GatewayRuntime` to `DiscordApp`.
##
## This opt-in composition module imports both layers without adding an app
## dependency to the Gateway umbrella. It maps the runtime's start, join, and
## close operations to one `AppLifecycle`; the runtime remains the sole owner of
## its supervisor task.

import chronos

import cordnim/app
import cordnim/gateway/runtime

proc attachGatewayRuntime*[S](app: DiscordApp[S], runtime: GatewayRuntime) =
  ## Attaches an owned `GatewayRuntime` as an application runtime component.
  ##
  ## The adapter starts the runtime, joins its terminal outcome, and closes it
  ## without creating another background task.
  ##
  ## Raises `ValueError` for a nil app or runtime, or for an application whose
  ## configuration needs no Gateway connection, and `AppLifecycleError` if the
  ## app has already left the ready state.
  if app.isNil:
    raise newException(ValueError,
      "gateway runtime attachment requires an application")
  if runtime.isNil:
    raise newException(ValueError,
      "gateway runtime attachment requires a runtime")
  if not app.config.requiresGatewayConnection():
    raise newException(ValueError,
      "gateway runtime attachment requires Gateway interaction ingress or " &
      "event subscriptions")
  if app.lifecycleState != alsReady:
    raise newException(AppLifecycleError,
      "application runtime components can only be attached while ready")

  proc startHook(): Future[void] {.closure, gcsafe, raises: [].} =
    proc startOwned(): Future[void] {.async.} =
      runtime.start()
    {.cast(gcsafe).}:
      return startOwned()

  proc waitHook(): Future[void] {.closure, gcsafe, raises: [].} =
    proc waitOwned(): Future[void] {.async.} =
      await runtime.join()
    {.cast(gcsafe).}:
      return waitOwned()

  proc closeHook(): Future[void] {.closure, gcsafe, raises: [].} =
    proc closeOwned(): Future[void] {.async.} =
      await runtime.close()
    {.cast(gcsafe).}:
      return closeOwned()

  app.configureLifecycle(initAppLifecycle(startHook, waitHook, closeHook))
