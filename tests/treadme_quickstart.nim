## Compile-only mirror of the README HTTP quickstart.

import std/os

import chronos
import cordnim

type Services = object
  greeting: string

proc hello(ctx: CommandCtx[Services], name: string): Future[CommandResult]
    {.async, discordCommand(
      name = "hello",
      description = "Say hello",
      installs = {guildInstall, userInstall},
      contexts = {guildChannel, botDm, privateChannel}
    ).} =
  await ctx.reply(ctx.services.greeting & ", " & name)
  return succeeded()

proc compileQuickstart() =
  let app = newDiscordApp(
    Services(greeting: "Hello"),
    initAppConfig(ingressHttp),
    commandSet(hello)
  )
  let publicKey = parseEd25519PublicKey(getEnv("DISCORD_PUBLIC_KEY"))
  discard newInteractionHttpRuntime(
    app,
    initTAddress("127.0.0.1:8080"),
    sodiumVerificationConfig(publicKey)
  )

if false:
  compileQuickstart()
