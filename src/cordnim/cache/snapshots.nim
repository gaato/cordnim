## Immutable values annotated with cache revision and observation time.

type Snapshot*[T] = object ## Immutable cache observation of a Discord entity.
  data: T
  revision*: uint64 ## Store-local monotonically increasing revision.
  observedAtMs*: int64 ## Monotonic timestamp at which the value was observed.

proc initSnapshot*[T](
    value: sink T;
    revision: uint64;
    observedAtMs: int64,
): Snapshot[T] =
  ## Moves `value` into an immutable snapshot with caller-supplied metadata.
  Snapshot[T](
    data: value,
    revision: revision,
    observedAtMs: observedAtMs,
  )

func value*[T](snapshot: Snapshot[T]): lent T =
  ## Borrows the contained value without copying or permitting mutation.
  snapshot.data

func isNewerThan*[T](snapshot: Snapshot[T]; revision: uint64): bool {.raises: [].} =
  ## Tests whether this snapshot was stored after `revision`.
  snapshot.revision > revision
