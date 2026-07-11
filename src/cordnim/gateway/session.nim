## Resumable Gateway session cursors and an in-memory persistence adapter.

import std/[hashes, options, tables]

type
  ShardId* = distinct uint16 ## Zero-based shard identifier within a shard set.
  GatewaySequence* = distinct int64 ## Dispatch sequence used for ordered
    ## resume.

  SequenceObservation* = enum ## Relationship between a dispatch and stored
    ## sequence.
    sequenceAdvanced, ## Sequence increased and the resume cursor was updated.
    sequenceRepeated, ## Sequence matched the cursor and storage was unchanged.
    sequenceRegressed ## Sequence decreased and storage was unchanged.

  GatewaySessionState* = object ## Mutable resume state for one Gateway shard.
    shardId*: ShardId ## Shard that owns this session.
    sessionId*: string ## Discord session identifier from READY.
    resumeGatewayUrl*: string ## Resume URL supplied by Discord.
    sequence*: Option[GatewaySequence] ## Latest advancing dispatch sequence.
    resumable*: bool ## Whether Discord still permits attempting a resume.

  ResumeCursor* = object ## Complete immutable Gateway RESUME inputs.
    sessionId*: string ## Discord session identifier.
    resumeGatewayUrl*: string ## Gateway endpoint on which to resume.
    sequence*: GatewaySequence ## Last accepted dispatch sequence.

  MemorySessionStore* = object ## Process-local session store for tests and
    ## simple deployments.
    sessions: Table[ShardId, GatewaySessionState]

func `==`*(a, b: ShardId): bool {.borrow.}
  ## Compares shard numbers.
func hash*(value: ShardId): Hash {.raises: [].} =
  ## Hashes the shard number for session-store keys.
  hash(uint16(value))
func toUint16*(value: ShardId): uint16 {.inline, raises: [].} =
  ## Returns the raw shard number.
  uint16(value)

func `==`*(a, b: GatewaySequence): bool {.borrow.}
  ## Compares Gateway dispatch sequences.
func `<`*(a, b: GatewaySequence): bool {.borrow.}
  ## Orders Gateway dispatch sequences.
func `<=`*(a, b: GatewaySequence): bool {.borrow.}
  ## Orders Gateway dispatch sequences.
func toInt64*(value: GatewaySequence): int64 {.inline, raises: [].} =
  ## Returns the raw signed sequence value.
  int64(value)

func initGatewaySession*(shardId: ShardId): GatewaySessionState {.raises: [].} =
  ## Creates non-resumable state for `shardId`.
  GatewaySessionState(shardId: shardId)

proc recordReady*(
    state: var GatewaySessionState;
    sessionId, resumeGatewayUrl: sink string,
) =
  ## Records READY identifiers and marks the session as potentially resumable.
  ##
  ## A sequence must still be observed before `canResume` returns true.
  if sessionId.len == 0:
    raise newException(ValueError, "gateway session ID must not be empty")
  if resumeGatewayUrl.len == 0:
    raise newException(ValueError, "resume gateway URL must not be empty")

  state.sessionId = sessionId
  state.resumeGatewayUrl = resumeGatewayUrl
  state.resumable = true

proc observeSequence*(
    state: var GatewaySessionState;
    sequence: GatewaySequence,
): SequenceObservation {.raises: [].} =
  ## Retains only a strictly advancing dispatch sequence.
  if state.sequence.isNone:
    state.sequence = some(sequence)
    return sequenceAdvanced

  let current = state.sequence.get
  # Repeated or regressed events are reported but never poison the resume
  # cursor that Discord expects to be the highest successfully observed value.
  if sequence < current:
    sequenceRegressed
  elif sequence == current:
    sequenceRepeated
  else:
    state.sequence = some(sequence)
    sequenceAdvanced

func canResume*(state: GatewaySessionState): bool {.raises: [].} =
  ## Tests whether every field required by a RESUME payload is present.
  state.resumable and state.sessionId.len > 0 and
    state.resumeGatewayUrl.len > 0 and state.sequence.isSome

proc resumeCursor*(state: GatewaySessionState): ResumeCursor =
  ## Returns complete resume inputs or raises `ValueError` if unavailable.
  if not state.canResume:
    raise newException(
      ValueError,
      "gateway session does not have a resumable cursor",
    )
  ResumeCursor(
    sessionId: state.sessionId,
    resumeGatewayUrl: state.resumeGatewayUrl,
    sequence: state.sequence.get,
  )

proc invalidate*(state: var GatewaySessionState) {.raises: [].} =
  ## Erases all resume credentials and dispatch progress.
  state.sessionId.setLen(0)
  state.resumeGatewayUrl.setLen(0)
  state.sequence = none(GatewaySequence)
  state.resumable = false

func initMemorySessionStore*(): MemorySessionStore {.raises: [].} =
  ## Creates an empty process-local session store.
  MemorySessionStore(sessions: initTable[ShardId, GatewaySessionState]())

proc put*(store: var MemorySessionStore; state: GatewaySessionState) {.
    raises: [].} =
  ## Stores a copy of the latest state for its shard.
  store.sessions[state.shardId] = state

func get*(
    store: MemorySessionStore;
    shardId: ShardId,
): Option[GatewaySessionState] {.raises: [].} =
  ## Returns stored state without performing external I/O.
  if store.sessions.hasKey(shardId):
    some(store.sessions.getOrDefault(shardId))
  else:
    none(GatewaySessionState)

func contains*(store: MemorySessionStore; shardId: ShardId): bool {.
    raises: [].} =
  ## Tests whether state for `shardId` is stored.
  store.sessions.hasKey(shardId)

proc del*(store: var MemorySessionStore; shardId: ShardId) {.raises: [].} =
  ## Deletes state for `shardId` if present.
  store.sessions.del(shardId)

proc clear*(store: var MemorySessionStore) {.raises: [].} =
  ## Deletes every stored session.
  store.sessions.clear()

func len*(store: MemorySessionStore): int {.inline, raises: [].} =
  ## Returns the number of stored shard sessions.
  store.sessions.len
