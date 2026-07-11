## Deterministic distribution of Gateway shards across processes.

import ./session

type
  ShardRange* = object ## Half-open range of shard identifiers owned by a process.
    first*: uint16 ## First owned shard identifier.
    lastExclusive*: uint16 ## One past the final owned shard identifier.

  ShardPlan* = object ## Validated contiguous shard assignment for one process.
    totalShards*: uint16 ## Total shard count used by the application.
    processIndex*: uint16 ## Zero-based index of this process.
    processCount*: uint16 ## Number of cooperating processes.
    owned*: ShardRange ## Contiguous shard range assigned to this process.

proc planShards*(
    totalShards, processIndex, processCount: uint16,
): ShardPlan =
  ## Evenly assigns contiguous shards, giving earlier processes one extra.
  ##
  ## Raises `ValueError` when counts or the process index are invalid.
  if totalShards == 0:
    raise newException(ValueError, "total shard count must be at least one")
  if processCount == 0:
    raise newException(ValueError, "process count must be at least one")
  if processIndex >= processCount:
    raise newException(ValueError, "process index must be less than process count")

  let total = uint32(totalShards)
  let count = uint32(processCount)
  let index = uint32(processIndex)
  let base = total div count
  let remainder = total mod count
  # Assigning remainder shards to the first processes makes every process's
  # range derivable from the same three integers without shared state.
  let extraBefore = min(index, remainder)
  let first = index * base + extraBefore
  let size = base + (if index < remainder: 1'u32 else: 0'u32)

  ShardPlan(
    totalShards: totalShards,
    processIndex: processIndex,
    processCount: processCount,
    owned: ShardRange(
      first: uint16(first),
      lastExclusive: uint16(first + size),
    ),
  )

iterator shardIds*(plan: ShardPlan): ShardId =
  ## Yields every shard owned by `plan` in ascending order.
  for value in plan.owned.first ..< plan.owned.lastExclusive:
    yield ShardId(value)

func len*(range: ShardRange): int {.inline, raises: [].} =
  ## Returns the number of shard identifiers in the half-open range.
  int(range.lastExclusive - range.first)
