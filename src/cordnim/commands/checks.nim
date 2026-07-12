## Reusable synchronous command checks implemented as ordinary app middleware.
##
## Checks inspect a transport-independent `CommandInvocation` before its
## handler runs. They do not perform I/O; authorization that needs an awaited
## lookup belongs in a handler or an explicitly asynchronous application layer.

import std/options

import cordnim/app
import cordnim/core/[bits, ids, permissions]
import cordnim/interactions/context
import ./spec

type
  CommandCheckKind* = enum ## Outcome of one pre-dispatch command check.
    cckPassed, ## Continue to the next check.
    cckRejected ## Stop dispatch with a user-safe rejection message.

  CommandCheckResult* = object ## Stable check outcome without exceptions.
    case kind*: CommandCheckKind ## Passed or rejected discriminator.
    of cckPassed:
      discard
    of cckRejected:
      message*: string ## User-safe reason returned as `crRejected`.

  CommandCheck*[S] = proc(
      services: ref S;
      invocation: CommandInvocation,
    ): CommandCheckResult {.closure.} ## Read-only synchronous predicate.

func checkPassed*(): CommandCheckResult =
  ## Creates a successful check result.
  CommandCheckResult(kind: cckPassed)

func checkRejected*(message: string): CommandCheckResult =
  ## Creates a rejected check result with a user-safe message.
  CommandCheckResult(kind: cckRejected, message: message)

proc checkMiddleware*[S](
    name: string;
    checks: openArray[CommandCheck[S]],
): CommandMiddleware[S] =
  ## Combines ordered checks into one short-circuiting app middleware.
  if name.len == 0:
    raise newException(ValueError, "command check middleware needs a name")
  if checks.len == 0:
    raise newException(ValueError,
      "command check middleware needs at least one check")
  let ownedChecks = @checks
  result = CommandMiddleware[S](name: name)
  result.before = proc(
      services: ref S;
      invocation: var CommandInvocation,
  ): MiddlewareDecision =
    for check in ownedChecks:
      if check.isNil:
        raise newException(ValueError, "command check must not be nil")
      let decision = check(services, invocation)
      if decision.kind == cckRejected:
        return stopDispatch(rejected(decision.message))
    continueDispatch()

proc guildOnlyCheck*[S](
    message = "this command is only available in a guild",
): CommandCheck[S] =
  ## Creates a check that rejects direct-message invocations.
  result = proc(services: ref S; invocation: CommandInvocation):
      CommandCheckResult =
    discard services
    if invocation.guildId.isSome: checkPassed() else: checkRejected(message)

proc directMessageOnlyCheck*[S](
    message = "this command is only available in a direct message",
): CommandCheck[S] =
  ## Creates a check that rejects guild invocations.
  result = proc(services: ref S; invocation: CommandInvocation):
      CommandCheckResult =
    discard services
    if invocation.guildId.isNone: checkPassed() else: checkRejected(message)

proc installationCheck*[S](
    required: InstallationKind;
    message = "this installation cannot use the command",
): CommandCheck[S] =
  ## Creates a check for a guild-owned or user-owned installation.
  result = proc(services: ref S; invocation: CommandInvocation):
      CommandCheckResult =
    discard services
    if invocation.context.hasOwner(required):
      checkPassed()
    else:
      checkRejected(message)

proc userCheck*[S](
    allowed: openArray[UserId];
    message = "this user cannot use the command",
): CommandCheck[S] =
  ## Creates an allow-list check over typed user IDs.
  let users = @allowed
  result = proc(services: ref S; invocation: CommandInvocation):
      CommandCheckResult =
    discard services
    if invocation.userId in users: checkPassed() else: checkRejected(message)

func hasRequiredPermissions(actual, required: Permissions): bool =
  actual.contains(Permission.administrator) or actual.containsAll(required)

proc memberPermissionsCheck*[S](
    required: Permissions;
    message = "you do not have the required permissions",
): CommandCheck[S] =
  ## Creates a check over the invoking guild member's effective permissions.
  result = proc(services: ref S; invocation: CommandInvocation):
      CommandCheckResult =
    discard services
    if invocation.context.memberPermissions.isSome and
        invocation.context.memberPermissions.get().hasRequiredPermissions(
          required):
      checkPassed()
    else:
      checkRejected(message)

proc appPermissionsCheck*[S](
    required: Permissions;
    message = "the application does not have the required permissions",
): CommandCheck[S] =
  ## Creates a check over the application's effective channel permissions.
  result = proc(services: ref S; invocation: CommandInvocation):
      CommandCheckResult =
    discard services
    if invocation.context.appPermissions.hasRequiredPermissions(required):
      checkPassed()
    else:
      checkRejected(message)
