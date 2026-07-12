## App-level integration test for the Gateway runtime lifecycle adapter.

import std/unittest

import chronos

import cordnim/app
import cordnim/app/gateway_runtime
import cordnim/commands
import cordnim/gateway/runtime
import cordnim/gateway/sharding
import cordnim/gateway/session
import cordnim/gateway/shard_runner

type GatewayAppServices = object

proc unusedFactory(shardId: ShardId): GatewayShardRunner
    {.gcsafe, raises: [ValueError].} =
  discard shardId
  raise newException(ValueError, "runner factory must not be called")

proc emptyRuntime(): GatewayRuntime =
  # This process owns zero of the one planned shard, so no runner is built and
  # start, join, and close are all no-ops that exercise the adapter wiring.
  newGatewayRuntime(planShards(1, 1, 2), unusedFactory)

proc newGatewayApp(): DiscordApp[GatewayAppServices] =
  newDiscordApp(GatewayAppServices(), initAppConfig(ingressGateway),
    initCommandSet[GatewayAppServices]())

suite "attachGatewayRuntime":
  test "attaches an owned runtime and drives its complete lifecycle":
    let application = newGatewayApp()
    let runtime = emptyRuntime()
    check runtime.runnerCount == 0
    attachGatewayRuntime(application, runtime)
    check application.hasLifecycle
    check application.runtimeCount == 1
    waitFor application.run()
    check application.lifecycleState == alsClosed

  test "rejects a nil runtime, a nil app, and a webhook-only app":
    let application = newGatewayApp()
    expect ValueError:
      attachGatewayRuntime(application, GatewayRuntime(nil))
    expect ValueError:
      attachGatewayRuntime(DiscordApp[GatewayAppServices](nil), emptyRuntime())
    let webhookApp = newDiscordApp(
      GatewayAppServices(), initAppConfig(ingressHttp),
      initCommandSet[GatewayAppServices]())
    expect ValueError:
      attachGatewayRuntime(webhookApp, emptyRuntime())

  test "rejects attachment after the app has left the ready state":
    proc scenario(): Future[bool] {.async.} =
      let application = newGatewayApp()
      attachGatewayRuntime(application, emptyRuntime())
      await application.start()                 # now alsRunning, no longer ready
      var rejected = false
      try:
        attachGatewayRuntime(application, emptyRuntime())
      except AppLifecycleError:
        rejected = true
      await application.close()
      return rejected

    check waitFor scenario()
