## Compile-only mirror of the README Gateway quickstart.

import std/os

import chronos
import cordnim
import cordnim/bot

type Services = object
  greeting: string

proc compileGatewayQuickstart() =
  let app = newDiscordApp(
    Services(greeting: "Hello"),
    initAppConfig(
      ingressGateway,
      gatewaySubscriptions({giGuildMessages, giMessageContent})
    ),
    initCommandSet[Services]()
  )
  let token = initSecret[BotToken](getEnv("DISCORD_BOT_TOKEN"))
  let bot = newGatewayBotRuntime(app, token, singleProcessGateway())
  bot.events.onMessageCreate proc(
      ctx: GatewayEventContext[Services]; message: Message
  ): Future[void] {.async.} =
    echo ctx.services.greeting, ": ", message.content

if false:
  compileGatewayQuickstart()
