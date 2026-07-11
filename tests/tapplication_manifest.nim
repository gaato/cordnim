import std/[json, unittest]

import cordnim

type Services = object

proc deploy(context: CommandCtx[Services]): CommandResult
    {.discordCommand(
      name = "deploy",
      description = "Deploy an application",
      installs = {guildInstall, userInstall},
      requiredBotPermissions = {
        Permission.sendMessages, Permission.attachFiles
      }
    ).} =
  succeeded()

suite "application manifest":
  test "unions command install, permission, and explicit intent requirements":
    let application = newDiscordApp(
      Services(),
      initAppConfig(ingressHttp,
        gatewaySubscriptions({giGuilds, giGuildVoiceStates})),
      commandSet(deploy)
    )
    let manifest = initApplicationManifest(application, "2026-07-11")
    let document = manifest.toJson()
    check document["gatewayIntents"].len == 2
    check document["installContexts"].len == 2
    check document["requiredBotPermissions"].len == 2
    check document["requiredBotPermissionBits"].getStr() == "34816"
