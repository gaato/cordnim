import std/unittest

import chronos

import cordnim/runtime

suite "structured task scope":
  test "shutdown cancels and joins retained children":
    proc scenario(): Future[bool] {.async.} =
      let scope = newTaskScope()
      let child = sleepAsync(1.hours)
      discard scope.spawn(child)
      await scope.cancelAndJoin()
      return scope.isClosed and scope.len == 0 and child.cancelled
    check waitFor scenario()
