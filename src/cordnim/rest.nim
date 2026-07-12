## Scheduled Discord REST requests over a supervised Chronos HTTP transport.
##
## A `ChronosRestClient` owns one worker and drains queued and in-flight work on
## `stop`. The scheduler learns Discord bucket IDs, enforces global and
## per-bucket reset times, and replays requests only when `RequestMeta` carries
## idempotency evidence. Deadlines and cancellation groups produce typed
## `DiscordError` categories.
##
## Request bodies stay explicit and replayable. The HTTP adapter supports
## bounded static bodies and streamed multipart sources, applies response size
## limits, and keeps rendered token-bearing paths out of public errors. Use
## `submitChecked` when non-2xx responses should raise typed errors; raw callers
## can inspect every `TransportResponse` themselves.

import cordnim/core/fields
import cordnim/rest/[checked, chronos_driver, http_transport, multipart,
  raw_bridge, request, scheduler]

export checked, chronos_driver, fields, http_transport, multipart, raw_bridge,
  request, scheduler
