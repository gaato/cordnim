## Application configuration, middleware, test harness, and metrics tests.

import std/[json, options, unittest]
import chronos

import cordnim/[app, commands]
import cordnim/core/ids
import cordnim/observability/all
import cordnim/testing/all

type AppServices = object
  prefix: string

proc hello(ctx: CommandCtx[AppServices], name: string): CommandResult
    {.discordCommand(name = "hello", description = "Say hello").} =
  succeeded(ctx.services.prefix & name)

let registry = commandSet(hello)

suite "DiscordApp":
  test "keeps interaction ingress exclusive from optional Gateway events":
    let webhook = initAppConfig(ingressHttp)
    check webhook.appMode == webhookOnly
    check not webhook.requiresGatewayConnection

    let hybridConfig = initAppConfig(ingressHttp,
      gatewaySubscriptions({giGuildVoiceStates}))
    check hybridConfig.appMode == hybrid
    check hybridConfig.requiresGatewayConnection
    check hybridConfig.interactionIngress == ingressHttp

    let gateway = initAppConfig(ingressGateway,
      gatewaySubscriptions({giGuilds}))
    check gateway.appMode == gatewayOnly
    check gateway.requiresGatewayConnection

  test "runs pre-hooks in order and post-hooks in reverse order":
    var trace: seq[string]
    let application = newDiscordApp(
      AppServices(prefix: "hello "),
      initAppConfig(ingressHttp),
      registry
    )
    application.use CommandMiddleware[AppServices](
      name: "outer",
      before: proc (services: AppServices,
                    invocation: var CommandInvocation): MiddlewareDecision =
        trace.add("outer-before")
        continueDispatch(),
      after: proc (services: AppServices, invocation: CommandInvocation,
                  result: var CommandResult) =
        trace.add("outer-after")
    )
    application.use CommandMiddleware[AppServices](
      name: "inner",
      before: proc (services: AppServices,
                    invocation: var CommandInvocation): MiddlewareDecision =
        trace.add("inner-before")
        continueDispatch(),
      after: proc (services: AppServices, invocation: CommandInvocation,
                  result: var CommandResult) =
        trace.add("inner-after")
    )

    let result = waitFor application.dispatch(CommandInvocation(
      name: "hello",
      options: %*{"name": "Nim"},
      userId: toId(UserId, 42),
      guildId: none(GuildId)
    ))
    check result.message == "hello Nim"
    check trace == @[
      "outer-before", "inner-before", "inner-after", "outer-after"
    ]

  test "short-circuits a rejected invocation and unwinds entered middleware":
    var afterReached = false
    let application = newDiscordApp(
      AppServices(prefix: "unused "),
      initAppConfig(ingressHttp),
      registry
    )
    application.use CommandMiddleware[AppServices](
      name: "policy",
      before: proc (services: AppServices,
                    invocation: var CommandInvocation): MiddlewareDecision =
        stopDispatch(rejected("denied")),
      after: proc (services: AppServices, invocation: CommandInvocation,
                  result: var CommandResult) =
        afterReached = true
    )
    let result = waitFor application.dispatch(CommandInvocation(
      name: "hello",
      options: %*{"name": "Nim"},
      userId: toId(UserId, 42)
    ))
    check result.kind == crRejected
    check result.message == "denied"
    check afterReached

  test "records deterministic invocations in the testing harness":
    let testApp = testDiscordApp(
      AppServices(prefix: "hi "),
      initAppConfig(ingressHttp),
      registry
    )
    let result = waitFor testApp.invokeCommand(CommandInvocation(
      name: "hello",
      options: %*{"name": "Ada"},
      userId: toId(UserId, 1)
    ))
    result.expectSucceeded()
    result.expectMessageContains("Ada")
    check testApp.invocations.len == 1
    check testApp.results.len == 1

  test "exposes the complete stable metric name set":
    let names = standardMetricNames()
    check names.len == 19
    check interactionAckLatency in names
    check voiceDecodeDelay in names

  test "advances fake time without permitting reversal":
    var clock = initFakeClock(50)
    clock.advance(25)
    check clock.nowMs == 75
    expect ValueError:
      clock.advance(-1)
