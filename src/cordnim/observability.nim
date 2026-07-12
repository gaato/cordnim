## Transport-neutral structured logs and metric samples for runtime adapters.
##
## Applications provide the output backend. Recorder callbacks are
## synchronous, `gcsafe`, and non-raising; they must return without blocking
## the owning runtime loop. Secret overloads replace credential bytes with a
## fixed marker, while ordinary string attributes remain the caller's
## responsibility. Discord failure helpers omit exception messages and retain
## typed, redaction-safe metadata.

import cordnim/observability/all

export all
