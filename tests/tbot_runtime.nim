## Tests for high-level Gateway bot composition and production defaults.

import std/[json, options, strutils]

import chronos

import cordnim/[app, bot, commands]
import cordnim/core/secrets
import cordnim/api/gateway_bootstrap
import cordnim/gateway/[chronos_runtime, coordination, identify, intents]

type BotServices = object

proc emptyCommands(): CommandSet[BotServices] =
  initCommandSet[BotServices]()

proc gatewayApp(): DiscordApp[BotServices] =
  newDiscordApp(
    BotServices(),
    initAppConfig(
      ingressGateway,
      gatewaySubscriptions({giGuildMessages})),
    emptyCommands())

block complete_gateway_composition:
  let app = gatewayApp()
  let runtime = newGatewayBotRuntime(
    app,
    initSecret[BotToken]("test-token"),
    singleProcessGateway())
  doAssert app.runtimeCount == 1
  doAssert not runtime.events.isNil
  doAssert not runtime.interactions.isNil
  doAssert not runtime.rest.isNil
  doAssert "test-token" notin $runtime
  doAssert "test-token" notin repr(runtime)
  waitFor app.close()
  doAssert app.lifecycleState == alsClosed

block http_ingress_uses_its_own_dispatcher:
  let app = newDiscordApp(
    BotServices(),
    initAppConfig(
      ingressHttp,
      gatewaySubscriptions({giGuildMessages})),
    emptyCommands())
  let runtime = newGatewayBotRuntime(
    app,
    initSecret[BotToken]("test-token"),
    singleProcessGateway())
  doAssert not runtime.events.isNil
  doAssertRaises ValueError:
    discard runtime.interactions
  waitFor app.close()

block webhook_only_is_rejected:
  let app = newDiscordApp(
    BotServices(), initAppConfig(ingressHttp), emptyCommands())
  doAssertRaises ValueError:
    discard newGatewayBotRuntime(
      app,
      initSecret[BotToken]("test-token"),
      singleProcessGateway())

block local_coordination_cannot_span_processes:
  let app = gatewayApp()
  doAssertRaises ValueError:
    discard newGatewayBotRuntime(
      app,
      initSecret[BotToken]("test-token"),
      singleProcessGateway(),
      initGatewayBotOptions(processCount = 2))

block coordination_choice_is_required:
  let app = gatewayApp()
  doAssertRaises ValueError:
    discard newGatewayBotRuntime(
      app,
      initSecret[BotToken]("test-token"),
      GatewayBotCoordination())

block invalid_options_are_rejected_before_io:
  let app = gatewayApp()
  doAssertRaises ValueError:
    discard newGatewayBotRuntime(
      app,
      initSecret[BotToken]("test-token"),
      singleProcessGateway(),
      initGatewayBotOptions(shardCount = some(0'u16)))

block chronos_dependencies_are_bounded:
  doAssert chronosGatewayClock() >= 0
  doAssert secureGatewayJitter(0) == 0
  for _ in 0 ..< 100:
    let value = secureGatewayJitter(17)
    doAssert value >= 0 and value <= 17
  waitFor chronosGatewaySleep(0)
  let factory = chronosGatewayTransportFactory(1_024)
  doAssert not factory().isNil
  doAssert not factory().isNil
  doAssertRaises ValueError:
    discard chronosGatewayTransportFactory(0)

block injected_bootstrap_drives_the_full_lifecycle_without_network:
  let bootstrap = decodeGatewayBotInfo(%*{
    "url": "wss://gateway.discord.gg",
    "shards": 1,
    "session_start_limit": {
      "total": 100,
      "remaining": 100,
      "reset_after": 60_000,
      "max_concurrency": 1
    }
  })
  let coordination = newLocalGatewayCoordination(
    chronosGatewayClock,
    60_000,
    SessionStartLimit(
      total: 100,
      remaining: 100,
      resetAfterMs: 60_000,
      maxConcurrency: 1)).asCoordination()
  let app = gatewayApp()
  discard newGatewayBotRuntime(
    app,
    initSecret[BotToken]("test-token"),
    externalGateway(coordination),
    initGatewayBotOptions(
      processIndex = 1,
      processCount = 2,
      shardCount = some(1'u16),
      gatewayBotInfo = some(bootstrap)))
  waitFor app.run()
  doAssert app.lifecycleState == alsClosed
