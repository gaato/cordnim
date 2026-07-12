## Focused application facade and response-context tests.

import std/[assertions, json]

import chronos

import cordnim/[app, commands]
import cordnim/app/context as appcontext
import cordnim/interactions/[context, exchange, responder]
import cordnim/rest/chronos_driver

static:
  doAssert not declared(dispatchWithServices)

func sampleInvocation(publicResponses = true): InvocationContext =
  InvocationContext(
    responsePolicy: ResponsePolicy(
      publicResponseAllowed: publicResponses
    )
  )

proc completeNow(): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.test.complete")
  result.complete()

proc failNow(message: string): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.test.failure")
  result.fail(newException(ValueError, message))

proc cancelNow(message: string): Future[void] {.raises: [].} =
  result = newFuture[void]("cordnim.test.cancel")
  result.fail(newException(CancelledError, message))

block config_keeps_ingress_and_events_separate:
  let webhook = initAppConfig(ingressHttp)
  doAssert webhook.interactionIngress == ingressHttp
  doAssert webhook.appMode == webhookOnly
  doAssert not webhook.requiresGatewayConnection
  doAssert not webhook.gatewayEvents.enabled

  let hybridConfig = initAppConfig(
    ingressHttp,
    gatewaySubscriptions({giGuildVoiceStates})
  )
  doAssert hybridConfig.interactionIngress == ingressHttp
  doAssert hybridConfig.gatewayEvents.enabled
  doAssert hybridConfig.gatewayEvents.intents == {giGuildVoiceStates}
  doAssert hybridConfig.appMode == hybrid
  doAssert hybridConfig.requiresGatewayConnection

  let gateway = initAppConfig(ingressGateway)
  doAssert gateway.interactionIngress == ingressGateway
  doAssert gateway.appMode == gatewayOnly
  doAssert gateway.requiresGatewayConnection

block lifecycle_runs_start_wait_close_in_order:
  var trace: seq[string]
  let lifecycle = initAppLifecycle(
    start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        trace.add("start")
      completeNow(),
    wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        trace.add("wait")
      completeNow(),
    close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        trace.add("close")
      completeNow()
  )
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string](),
    lifecycle
  )

  doAssert application.hasLifecycle
  doAssert application.lifecycleState == alsReady
  doAssert application.services == "services"
  waitFor application.run()
  doAssert trace == @["start", "wait", "close"]
  doAssert application.lifecycleState == alsClosed

  waitFor application.close()
  doAssert trace == @["start", "wait", "close"]

block lifecycle_requires_owned_transport_operations:
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string]()
  )
  doAssert not application.hasLifecycle
  doAssertRaises AppLifecycleError:
    waitFor application.start()

block lifecycle_composes_multiple_components_while_ready:
  var trace: seq[string]
  let lifecycle = initAppLifecycle(
    start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        trace.add("start")
      completeNow(),
    wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        trace.add("wait")
      completeNow(),
    close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        trace.add("close")
      completeNow()
  )
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string]()
  )

  doAssertRaises ValueError:
    application.configureLifecycle(AppLifecycle())
  application.configureLifecycle(lifecycle)
  doAssert application.hasLifecycle
  application.configureLifecycle(lifecycle)
  doAssert application.runtimeCount == 2

  waitFor application.run()
  doAssert trace == @[
    "start", "start", "wait", "wait", "close", "close"]
  doAssert application.lifecycleState == alsClosed

block lifecycle_starts_in_order_and_closes_in_reverse:
  var trace: seq[string]

  proc component(name: string): AppLifecycle =
    initAppLifecycle(
      start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          trace.add("start:" & name)
        completeNow(),
      wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          trace.add("wait:" & name)
        completeNow(),
      close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
        {.cast(gcsafe).}:
          trace.add("close:" & name)
        completeNow()
    )

  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string]())
  application.configureLifecycle(component("http"))
  application.configureLifecycle(component("gateway"))

  waitFor application.run()
  doAssert trace == @[
    "start:http", "start:gateway",
    "wait:http", "wait:gateway",
    "close:gateway", "close:http"]

block close_during_start_joins_start_before_close_hook:
  let startGate = newFuture[void]("cordnim.test.start-gate")
  var startCalls = 0
  var closeCalls = 0
  var hooksOverlapped = false
  let lifecycle = initAppLifecycle(
    start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc startCalls
        result = startGate,
    wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      completeNow(),
    close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc closeCalls
        hooksOverlapped = not startGate.finished
      completeNow()
  )
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string](),
    lifecycle
  )

  let firstStart = application.start()
  let secondStart = application.start()
  doAssert firstStart == secondStart
  doAssert startCalls == 1
  doAssert not firstStart.finished

  let firstClose = application.close()
  let secondClose = application.close()
  doAssert firstClose == secondClose
  waitFor firstClose
  waitFor secondClose
  doAssert firstStart.cancelled
  doAssert not hooksOverlapped
  doAssert closeCalls == 1
  doAssert application.lifecycleState == alsClosed

block concurrent_run_calls_share_one_wait_hook:
  let waitEntered = newFuture[void]("cordnim.test.wait-entered")
  let waitGate = newFuture[void]("cordnim.test.wait-gate")
  var startCalls = 0
  var waitCalls = 0
  var closeCalls = 0
  let lifecycle = initAppLifecycle(
    start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc startCalls
      completeNow(),
    wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc waitCalls
        if not waitEntered.finished:
          waitEntered.complete()
        result = waitGate,
    close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc closeCalls
      completeNow()
  )
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string](),
    lifecycle
  )

  let firstRun = application.run()
  let secondRun = application.run()
  waitFor waitEntered
  doAssert startCalls == 1
  doAssert waitCalls == 1

  waitGate.complete()
  waitFor firstRun
  waitFor secondRun
  doAssert waitCalls == 1
  doAssert closeCalls == 1
  doAssert application.lifecycleState == alsClosed

block failed_close_remains_retryable:
  var closeCalls = 0
  let lifecycle = initAppLifecycle(
    start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      completeNow(),
    wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      completeNow(),
    close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc closeCalls
        if closeCalls == 1:
          return failNow("first close failed")
      completeNow()
  )
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string](),
    lifecycle
  )

  doAssertRaises ValueError:
    waitFor application.close()
  doAssert closeCalls == 1
  doAssert application.lifecycleState == alsClosing

  waitFor application.close()
  doAssert closeCalls == 2
  doAssert application.lifecycleState == alsClosed

block cancelled_close_remains_retryable:
  var closeCalls = 0
  let lifecycle = initAppLifecycle(
    start = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      completeNow(),
    wait = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      completeNow(),
    close = proc (): Future[void] {.closure, gcsafe, raises: [].} =
      {.cast(gcsafe).}:
        inc closeCalls
        if closeCalls == 1:
          return cancelNow("first close cancelled")
      completeNow()
  )
  let application = newDiscordApp(
    "services",
    initAppConfig(ingressHttp),
    initCommandSet[string](),
    lifecycle
  )

  doAssertRaises CancelledError:
    waitFor application.close()
  doAssert closeCalls == 1
  doAssert application.lifecycleState == alsClosing

  waitFor application.close()
  doAssert closeCalls == 2
  doAssert application.lifecycleState == alsClosed

block context_selects_one_initial_reply_and_applies_visibility:
  let exchange = newInteractionExchange(
    ikApplicationCommand,
    sampleInvocation(publicResponses = false),
    monotonicMillis()
  )
  let context = appcontext.newContext(exchange)

  waitFor context.reply("hello")
  doAssert context.responseState == irInitialPending
  let selected = waitFor exchange.initialResponse
  doAssert selected.action == raReply
  doAssert selected.visibility == vEphemeral
  doAssert selected.body == %*{"content": "hello"}

  doAssertRaises InteractionExchangeError:
    waitFor context.reply("duplicate")
  exchange.confirmInitialDelivery()
  doAssert context.responseState == irResponded

block context_defer_allows_edit_and_followup:
  var sent: seq[ContextResponse]
  let sender: ContextResponseSender = proc (
      response: ContextResponse
    ): Future[void] {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sent.add(response)
    completeNow()
  let exchange = newInteractionExchange(
    ikApplicationCommand,
    sampleInvocation(),
    monotonicMillis(),
    sender
  )
  let context = appcontext.newContext(exchange)

  waitFor context.deferReply(visibility = vEphemeral)
  let selected = waitFor exchange.initialResponse
  let edit = context.editOriginal(%*{"content": "ready"})
  doAssert not edit.finished
  exchange.confirmInitialDelivery()
  waitFor edit
  waitFor context.followup("done")
  doAssert context.responseState == irDeferred
  doAssert selected.action == raDefer
  doAssert sent.len == 2
  doAssert sent[0].action == raEditOriginal
  doAssert sent[1].action == raFollowup

block context_rejects_an_unsupported_initial_operation:
  let exchange = newInteractionExchange(
    ikApplicationCommand,
    sampleInvocation(),
    monotonicMillis()
  )
  let context = appcontext.newContext(exchange)

  doAssertRaises InteractionExchangeError:
    waitFor context.updateMessage(%*{"content": "not a component"})
  doAssert context.responseState == irFresh

block context_waits_for_delivery_before_post_ack_io:
  let exchange = newInteractionExchange(
    ikApplicationCommand,
    sampleInvocation(),
    monotonicMillis()
  )
  let context = appcontext.newContext(exchange)

  waitFor context.reply("hello")
  let edit = context.editOriginal(%*{"content": "never sent"})
  doAssert not edit.finished
  exchange.markInitialDeliveryUnknown()
  doAssertRaises InteractionDeliveryUnknownError:
    waitFor edit
  doAssert context.responseState == irTransportUnknown
