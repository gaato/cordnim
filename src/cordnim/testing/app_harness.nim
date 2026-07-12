## In-process command application harness for tests without Discord.

import std/strutils
import chronos

import cordnim/[app, commands]
import cordnim/app/context as appcontext

type
  TestDiscordApp*[S] = ref object ## Recorder around a real typed `DiscordApp`.
    app*: DiscordApp[S] ## Application under test.
    invocations*: seq[CommandInvocation] ## Invocation history in call order.
    results*: seq[CommandResult] ## Result history in call order.

proc testDiscordApp*[S](services: sink S, config: AppConfig,
                        commands: sink CommandSet[S]): TestDiscordApp[S] =
  ## Creates a deterministic application harness without network transports.
  new result
  result.app = newDiscordApp(services, config, commands)

proc invokeCommand*[S](testApp: TestDiscordApp[S],
                       invocation: sink CommandInvocation):
                       Future[CommandResult] {.async.} =
  ## Dispatches, awaits, and records one command invocation.
  if testApp.isNil:
    raise newException(ValueError, "cannot invoke through a nil test app")
  testApp.invocations.add(invocation)
  result = await testApp.app.dispatch(invocation)
  testApp.results.add(result)

proc invokeCommand*[S](testApp: TestDiscordApp[S];
                       context: appcontext.Context;
                       invocation: sink CommandInvocation):
                       Future[CommandResult] {.async.} =
  ## Dispatches with a real response capability and records the outcome.
  if testApp.isNil:
    raise newException(ValueError, "cannot invoke through a nil test app")
  if context.isNil:
    raise newException(ValueError, "response-capable invocation needs a context")
  testApp.invocations.add(invocation)
  result = await testApp.app.dispatch(context, invocation)
  testApp.results.add(result)

proc expectKind*(commandResult: CommandResult, expected: CommandResultKind) =
  ## Asserts an exact command result classification.
  if commandResult.kind != expected:
    raise newException(AssertionDefect,
      "expected " & $expected & ", got " & $commandResult.kind)

proc expectSucceeded*(commandResult: CommandResult) =
  ## Asserts that a command completed successfully.
  commandResult.expectKind(crSucceeded)

proc expectMessageContains*(commandResult: CommandResult, expected: string) =
  ## Asserts that a result message contains `expected`.
  if not commandResult.message.contains(expected):
    raise newException(AssertionDefect,
      "expected result message to contain: " & expected)
