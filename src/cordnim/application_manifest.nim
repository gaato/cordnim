## Operational application manifest derived from typed app declarations.
##
## This manifest complements Discord's command JSON. It records Gateway
## intents, installation contexts, and the union of permissions declared by
## handlers so CI and startup diagnostics can compare code with portal state.

import std/[enumutils, json, strutils]

import cordnim/[app, commands]
import cordnim/core/[bits, permissions]

type
  ApplicationManifest* = object ## Deterministic operational requirements for
                                ## one `DiscordApp`.
    schemaRevision*: string ## Pinned Discord schema revision.
    gatewayIntents*: set[GatewayIntent] ## Explicit Gateway subscriptions.
    installContexts*: set[CommandInstallContext] ## Command installation owners.
    requiredBotPermissions*: Permissions ## Union of handler declarations.

func initApplicationManifest*[S](application: DiscordApp[S],
                                 schemaRevision: string):
                                 ApplicationManifest =
  ## Derives operational requirements without opening a Discord connection.
  result.schemaRevision = schemaRevision
  if application.isNil:
    return
  result.gatewayIntents = application.config.gatewayEvents.intents
  for command in application.commands:
    result.installContexts = result.installContexts + command.installs
    # Union the serialized limbs so this aggregation never truncates the
    # arbitrary-width permission representation to a machine integer.
    for limbIndex, limb in command.requiredBotPermissions.toLimbs():
      for offset in 0..<64:
        if (limb and (1'u64 shl offset)) != 0:
          result.requiredBotPermissions.inclBit(limbIndex * 64 + offset)

func intentName(intent: GatewayIntent): string =
  let value = $intent
  if value.len > 2 and value[0] == 'g' and value[1] == 'i':
    value[2..^1]
  else:
    value

func installName(context: CommandInstallContext): string =
  case context
  of guildInstall: "GuildInstall"
  of userInstall: "UserInstall"

func permissionName(permission: Permission): string =
  let value = $permission
  if value.len == 0:
    return value
  result = newStringOfCap(value.len)
  result.add(value[0].toUpperAscii())
  if value.len > 1:
    result.add(value[1..^1])

func toJson*(manifest: ApplicationManifest): JsonNode =
  ## Serializes requirements with both exact bits and readable known names.
  result = %*{
    "schemaRevision": manifest.schemaRevision,
    "gatewayIntents": [],
    "installContexts": [],
    "requiredBotPermissionBits":
      manifest.requiredBotPermissions.toDecimal(),
    "requiredBotPermissions": []
  }
  for intent in GatewayIntent:
    if intent in manifest.gatewayIntents:
      result["gatewayIntents"].add(%intent.intentName())
  for context in CommandInstallContext:
    if context in manifest.installContexts:
      result["installContexts"].add(%context.installName())
  for permission in enumutils.items(Permission):
    if manifest.requiredBotPermissions.contains(permission):
      result["requiredBotPermissions"].add(%permission.permissionName())
