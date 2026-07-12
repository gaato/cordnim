## Command check middleware tests.

import std/[json, options, unittest]

import cordnim/[app, commands]
import cordnim/command_policies
import cordnim/core/[bits, ids, permissions]
import cordnim/interactions/context

type CheckServices = object
  reached: bool

proc invocation(guild = none(GuildId);
                memberPermissions = none(Permissions)):
                CommandInvocation =
  CommandInvocation(
    kind: ckChatInput,
    name: "checked",
    options: newJObject(),
    userId: toId(UserId, 7),
    guildId: guild,
    context: InvocationContext(
      surface: if guild.isSome: isGuildChannel else: isBotDm,
      invokingUserId: toId(UserId, 7),
      guildId: guild,
      memberPermissions: memberPermissions,
      appPermissions: initDiscordBits[Permission]()
    )
  )

suite "Command checks":
  test "short-circuits ordered checks through ordinary middleware":
    var trace: seq[string]
    let first: CommandCheck[CheckServices] = proc(
        services: ref CheckServices; invocation: CommandInvocation):
        CommandCheckResult =
      discard services
      discard invocation
      trace.add("first")
      checkRejected("denied")
    let second: CommandCheck[CheckServices] = proc(
        services: ref CheckServices; invocation: CommandInvocation):
        CommandCheckResult =
      discard services
      discard invocation
      trace.add("second")
      checkPassed()
    let middleware = checkMiddleware("policy", [first, second])
    var request = invocation()
    var services: ref CheckServices
    new services
    let decision = middleware.before(services, request)
    check decision.kind == mdStop
    check decision.result.kind == crRejected
    check decision.result.message == "denied"
    check trace == @["first"]

  test "checks guild context installations users and permissions":
    let guildId = toId(GuildId, 9)
    var permissions = initDiscordBits[Permission]([
      Permission.manageMessages, Permission.sendMessages])
    var request = invocation(some(guildId), some(permissions))
    request.context.integrationOwners = @[
      IntegrationOwner(kind: iiGuildInstall, guildId: guildId)]
    var services: ref CheckServices
    new services

    check guildOnlyCheck[CheckServices]()(services, request).kind ==
      cckPassed
    check installationCheck[CheckServices](iiGuildInstall)(
      services, request).kind == cckPassed
    check userCheck[CheckServices]([toId(UserId, 7)])(
      services, request).kind == cckPassed
    let required = initDiscordBits[Permission]([Permission.manageMessages])
    check memberPermissionsCheck[CheckServices](required)(
      services, request).kind == cckPassed

  test "administrator satisfies every known permission check":
    let administrator = initDiscordBits[Permission]([
      Permission.administrator])
    let required = initDiscordBits[Permission]([
      Permission.manageGuild, Permission.bypassSlowmode])
    let request = invocation(some(toId(GuildId, 3)), some(administrator))
    var services: ref CheckServices
    new services
    check memberPermissionsCheck[CheckServices](required)(
      services, request).kind == cckPassed

  test "arbitrary-width subset comparison does not truncate high bits":
    let actual = initDiscordBits[Permission]([0'u64, 1'u64 shl 6])
    let required = initDiscordBits[Permission]([0'u64, 1'u64 shl 6])
    let absent = initDiscordBits[Permission]([0'u64, 1'u64 shl 7])
    check actual.containsAll(required)
    check not actual.containsAll(absent)
    check actual.missingBits(absent) == absent
