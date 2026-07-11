## Structured ownership for Chronos child tasks.

import chronos

type
  TaskScope* = ref object ## Group of child tasks cancelled and joined together.
    children: seq[Future[void]]
    closed: bool

proc newTaskScope*(): TaskScope =
  ## Creates an open task scope.
  TaskScope()

proc reap*(scope: TaskScope) =
  ## Removes completed children while preserving unfinished ownership.
  var active: seq[Future[void]]
  for child in scope.children:
    if not child.finished:
      active.add child
  scope.children = move active

proc spawn*(scope: TaskScope, child: Future[void]): Future[void] =
  ## Registers an already-created Chronos task as a child.
  ##
  ## Raises `ValueError` when shutdown has closed the scope.
  if scope.closed:
    child.cancelSoon()
    raise newException(ValueError, "cannot spawn into a closed task scope")
  scope.reap()
  scope.children.add child
  child

func len*(scope: TaskScope): int =
  ## Returns currently retained child futures, including newly completed ones.
  scope.children.len

func isClosed*(scope: TaskScope): bool =
  ## Reports whether the scope rejects new children.
  scope.closed

proc cancelAndJoin*(scope: TaskScope): Future[void] {.
                    async: (raises: []).} =
  ## Closes the scope, requests cancellation, and waits for every child.
  if scope.closed and scope.children.len == 0:
    return
  scope.closed = true
  if scope.children.len > 0:
    await cancelAndWait(scope.children)
  scope.children.setLen(0)
