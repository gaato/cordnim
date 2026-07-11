## Response-capable generated command adapter tests.

import std/[assertions, json]

import chronos

import cordnim/[app, commands]
import cordnim/app/context as appcontext
import cordnim/interactions/[context, exchange, responder]
import cordnim/rest/chronos_driver

type CommandServices = object
  prefix: string

proc respond(context: CommandCtx[CommandServices], action: string):
    Future[CommandResult]
    {.async, discordCommand(
      name = "respond",
      description = "Exercise response-capable command context"
    ).} =
  case action
  of "reply":
    await context.reply(context.services.prefix & "reply")
    await context.editOriginal(%*{"content": "edited"})
    await context.followup("followup", visibility = vEphemeral)
  of "defer":
    await context.deferReply(visibility = vEphemeral)
    await context.editOriginal(%*{"content": "deferred"})
  of "update":
    await context.updateMessage(%*{"content": "updated"})
  of "modal":
    await context.showModal(%*{
      "custom_id": "example",
      "title": "Example",
      "components": []
    })
  else:
    return rejected("unknown response action")
  return succeeded(action)

let responseCommands = commandSet(respond)

func commandInvocation(action: string): CommandInvocation =
  CommandInvocation(
    name: "respond",
    options: %*{"action": action},
    context: InvocationContext(
      responsePolicy: ResponsePolicy(publicResponseAllowed: true)
    )
  )

proc exercise(action: string, interactionType: InteractionType,
              throughApp = false): tuple[
                commandResult: CommandResult,
                responses: seq[ContextResponse],
                state: InteractionResponseState
              ] =
  var sent: seq[ContextResponse]
  let sender: ContextResponseSender = proc (
      response: ContextResponse
    ): Future[void] {.closure, gcsafe, raises: [].} =
    {.cast(gcsafe).}:
      sent.add(response)
    result = newFuture[void]("cordnim.test.command-response")
    result.complete()

  let invocation = commandInvocation(action)
  let exchange = newInteractionExchange(
    interactionType,
    invocation.context,
    monotonicMillis(),
    sender
  )
  let context = appcontext.newContext(exchange)
  let commandFuture =
    if throughApp:
      let application = newDiscordApp(
        CommandServices(prefix: "stored:"),
        initAppConfig(ingressHttp),
        responseCommands
      )
      application.dispatch(context, invocation)
    else:
      responseCommands.dispatch(
        CommandServices(prefix: "direct:"), context, invocation)
  let initial = waitFor exchange.initialResponse
  exchange.confirmInitialDelivery()
  let commandResult = waitFor commandFuture
  (commandResult, @[initial] & sent, context.responseState)

block generated_adapter_receives_ingress_context:
  let execution = exercise("reply", ikApplicationCommand)
  doAssert execution.commandResult.message == "reply"
  doAssert execution.state == irResponded
  doAssert execution.responses.len == 3
  doAssert execution.responses[0].action == raReply
  doAssert execution.responses[0].body == %*{"content": "direct:reply"}
  doAssert execution.responses[1].action == raEditOriginal
  doAssert execution.responses[2].action == raFollowup
  doAssert execution.responses[2].visibility == vEphemeral

block app_dispatch_uses_the_apps_authoritative_services:
  let execution = exercise("reply", ikApplicationCommand, throughApp = true)
  doAssert execution.commandResult.message == "reply"
  doAssert execution.state == irResponded
  doAssert execution.responses.len == 3
  doAssert execution.responses[0].action == raReply
  doAssert execution.responses[0].body == %*{"content": "stored:reply"}

block command_context_forwards_component_and_modal_responses:
  let update = exercise("update", ikMessageComponent)
  doAssert update.state == irResponded
  doAssert update.responses.len == 1
  doAssert update.responses[0].action == raUpdateMessage

  let modal = exercise("modal", ikApplicationCommand)
  doAssert modal.state == irResponded
  doAssert modal.responses.len == 1
  doAssert modal.responses[0].action == raModal

block result_only_dispatch_rejects_response_io:
  doAssertRaises CommandResponseUnavailableError:
    discard waitFor responseCommands.dispatch(
      CommandServices(prefix: "result-only:"),
      commandInvocation("reply")
    )
