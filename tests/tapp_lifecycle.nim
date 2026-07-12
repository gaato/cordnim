## App lifecycle error ordering, middleware unwind, and close behavior.

import std/[json, options, unittest]

import chronos

import cordnim/[app, commands]
import cordnim/core/ids

type LifecycleServices = object

proc okCommand(ctx: CommandCtx[LifecycleServices]): CommandResult
    {.discordCommand(name = "ok", description = "Succeeds").} =
  discard ctx
  succeeded("ok")

proc boomCommand(ctx: CommandCtx[LifecycleServices]): Future[CommandResult]
    {.async, discordCommand(name = "boom", description = "Raises").} =
  discard ctx
  raise newException(ValueError, "handler-boom")

let registry = commandSet(okCommand, boomCommand)

proc invocationOf(name: string): CommandInvocation =
  CommandInvocation(name: name, options: newJObject(),
    userId: toId(UserId, 42), guildId: none(GuildId))

proc tracingMiddleware(trace: ref seq[string]; label: string;
                       failBefore = false; failAfter = false):
    CommandMiddleware[LifecycleServices] =
  CommandMiddleware[LifecycleServices](
    name: label,
    before: proc (services: ref LifecycleServices,
                  invocation: var CommandInvocation): MiddlewareDecision =
      discard services
      discard invocation
      trace[].add label & "-before"
      if failBefore:
        raise newException(ValueError, label & "-before-boom")
      continueDispatch(),
    after: proc (services: ref LifecycleServices, invocation: CommandInvocation,
                 result: var CommandResult) =
      discard services
      discard invocation
      discard result
      trace[].add label & "-after"
      if failAfter:
        raise newException(ValueError, label & "-after-boom"))

# --- lifecycle hooks with no captured GC state (safe as gcsafe closures) ------

proc okStart(): Future[void] {.gcsafe, raises: [].} =
  result = newFuture[void]("test.start"); result.complete()
proc okWait(): Future[void] {.gcsafe, raises: [].} =
  result = newFuture[void]("test.wait"); result.complete()
proc okClose(): Future[void] {.gcsafe, raises: [].} =
  result = newFuture[void]("test.close"); result.complete()
proc failWaitFirst(): Future[void] {.gcsafe, raises: [].} =
  result = newFuture[void]("test.wait.first")
  result.fail(newException(ValueError, "first-wait-failed"))
proc failWaitSecond(): Future[void] {.gcsafe, raises: [].} =
  result = newFuture[void]("test.wait.second")
  result.fail(newException(ValueError, "second-wait-failed"))
proc failClose(): Future[void] {.gcsafe, raises: [].} =
  result = newFuture[void]("test.close.fail")
  result.fail(newException(ValueError, "close-failed"))

suite "app middleware unwinding":
  test "handler failure still unwinds every entered after in reverse":
    var trace = new(seq[string])
    let application = newDiscordApp(
      LifecycleServices(), initAppConfig(ingressHttp), registry)
    application.use tracingMiddleware(trace, "outer")
    application.use tracingMiddleware(trace, "inner")
    expect ValueError:
      discard waitFor application.dispatch(invocationOf("boom"))
    check trace[] == @[
      "outer-before", "inner-before", "inner-after", "outer-after"]

  test "a failing before still unwinds the already-entered outer after":
    var trace = new(seq[string])
    let application = newDiscordApp(
      LifecycleServices(), initAppConfig(ingressHttp), registry)
    application.use tracingMiddleware(trace, "outer")
    application.use tracingMiddleware(trace, "inner", failBefore = true)
    var message = ""
    try:
      discard waitFor application.dispatch(invocationOf("ok"))
    except ValueError as error:
      message = error.msg
    check message == "inner-before-boom"
    # The inner `before` failed, so inner is not entered and its after never
    # runs; the entered outer after still unwinds.
    check trace[] == @["outer-before", "inner-before", "outer-after"]

  test "an inner after failure never skips the outer after":
    var trace = new(seq[string])
    let application = newDiscordApp(
      LifecycleServices(), initAppConfig(ingressHttp), registry)
    application.use tracingMiddleware(trace, "outer")
    application.use tracingMiddleware(trace, "inner", failAfter = true)
    var message = ""
    try:
      discard waitFor application.dispatch(invocationOf("ok"))
    except ValueError as error:
      message = error.msg
    check message == "inner-after-boom"          # first failure is primary
    check trace[] == @[
      "outer-before", "inner-before", "inner-after", "outer-after"]

suite "app concurrent wait failures":
  test "a concurrent success never masks a concurrent wait failure":
    # `run` is start + wait + close; the wait error is surfaced through it.
    proc scenario(): Future[string] {.async.} =
      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(okStart, okWait, okClose))          # component 0 ok
      application.configureLifecycle(
        initAppLifecycle(okStart, failWaitSecond, okClose))  # component 1 fails
      var message = "no error"
      try:
        await application.run()
      except ValueError as error:
        message = error.msg
      return message

    check waitFor(scenario()) == "second-wait-failed"

  test "concurrent wait failures surface in attachment order":
    proc scenario(): Future[string] {.async.} =
      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(okStart, failWaitFirst, okClose))   # component 0 fails
      application.configureLifecycle(
        initAppLifecycle(okStart, failWaitSecond, okClose))  # component 1 fails
      var message = "no error"
      try:
        await application.run()
      except ValueError as error:
        message = error.msg
      return message

    check waitFor(scenario()) == "first-wait-failed"

suite "app run primary-error preservation":
  test "a close failure never overwrites the wait primary error":
    proc scenario(): Future[string] {.async.} =
      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(okStart, failWaitFirst, failClose))
      var message = "no error"
      try:
        await application.run()
      except ValueError as error:
        message = error.msg
      return message

    check waitFor(scenario()) == "first-wait-failed"

  test "a close failure is surfaced when there is no wait error":
    proc scenario(): Future[string] {.async.} =
      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(okStart, okWait, failClose))
      var message = "no error"
      try:
        await application.run()
      except ValueError as error:
        message = error.msg
      return message

    check waitFor(scenario()) == "close-failed"

suite "app close-hook contract":
  test "a partial start failure closes every attached component, even unstarted":
    proc scenario(): Future[seq[string]] {.async.} =
      let events = new(seq[string])
      proc startA(): Future[void] {.gcsafe, raises: [].} =
        events[].add "A-start"
        result = newFuture[void]("A.start"); result.complete()
      proc startB(): Future[void] {.gcsafe, raises: [].} =
        events[].add "B-start"
        result = newFuture[void]("B.start")
        result.fail(newException(ValueError, "B-start-failed"))
      proc startC(): Future[void] {.gcsafe, raises: [].} =
        events[].add "C-start"                 # C's start must never run
        result = newFuture[void]("C.start"); result.complete()
      proc closeA(): Future[void] {.gcsafe, raises: [].} =
        events[].add "A-close"
        result = newFuture[void]("A.close"); result.complete()
      proc closeB(): Future[void] {.gcsafe, raises: [].} =
        events[].add "B-close"
        result = newFuture[void]("B.close"); result.complete()
      proc closeC(): Future[void] {.gcsafe, raises: [].} =
        events[].add "C-close"
        result = newFuture[void]("C.close"); result.complete()

      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(startA, okWait, closeA))
      application.configureLifecycle(initAppLifecycle(startB, okWait, closeB))
      application.configureLifecycle(initAppLifecycle(startC, okWait, closeC))
      try:
        await application.start()
      except ValueError:
        discard
      return events[]

    let events = waitFor scenario()
    check "A-start" in events
    check "B-start" in events
    check "C-start" notin events                # start halted at the failure
    # Cleanup closes every attached component in reverse, including unstarted C.
    check "C-close" in events
    check "B-close" in events
    check "A-close" in events
    check events.find("C-close") < events.find("B-close")
    check events.find("B-close") < events.find("A-close")

  test "closing a never-started app still invokes the close hook":
    proc scenario(): Future[(int, AppLifecycleState)] {.async.} =
      let closed = new(int)
      closed[] = 0
      proc closeOnce(): Future[void] {.gcsafe, raises: [].} =
        closed[] = closed[] + 1
        result = newFuture[void]("unstarted.close"); result.complete()
      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(okStart, okWait, closeOnce))
      await application.close()                  # never started
      return (closed[], application.lifecycleState)

    let (closed, state) = waitFor scenario()
    check closed == 1
    check state == alsClosed

  test "a failed close leaves alsClosing and a later close retries":
    proc scenario(): Future[(int, AppLifecycleState, AppLifecycleState)]
        {.async.} =
      let attempts = new(int)
      attempts[] = 0
      proc closeFlaky(): Future[void] {.gcsafe, raises: [].} =
        attempts[] = attempts[] + 1
        result = newFuture[void]("flaky.close")
        if attempts[] == 1:
          result.fail(newException(ValueError, "close-retry-later"))
        else:
          result.complete()
      let application = newDiscordApp(
        LifecycleServices(), initAppConfig(ingressHttp),
        initCommandSet[LifecycleServices](),
        initAppLifecycle(okStart, okWait, closeFlaky))
      var afterFirst: AppLifecycleState
      try:
        await application.close()
      except ValueError:
        discard
      afterFirst = application.lifecycleState
      await application.close()                  # retry succeeds
      return (attempts[], afterFirst, application.lifecycleState)

    let (attempts, afterFirst, afterRetry) = waitFor scenario()
    check attempts == 2
    check afterFirst == alsClosing
    check afterRetry == alsClosed
