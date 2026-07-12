## Stable metric names and transport-neutral metric recording contracts.

type
  MetricAttribute* = object ## One low-cardinality metric attribute.
    key*: string ## Attribute key.
    value*: string ## Redacted attribute value.

  MetricSample* = object ## One unaggregated counter, gauge, ratio, or timing
    ## observation.
    name*: string ## Stable library metric name.
    value*: float64 ## Value in the unit documented by `name`.
    attributes*: seq[MetricAttribute] ## Low-cardinality dimensions.

  MetricRecorder* = proc(sample: MetricSample) {.closure, gcsafe, raises: [].}
    ## Synchronous, non-raising sink for one observation.
    ##
    ## A recorder is a passive observer: it must enqueue or account for the
    ## sample quickly and must never raise or block, because the runtime treats
    ## metric emission as infallible and does not guard the call. The adapter
    ## owns aggregation and export.

const
  interactionAckLatency* = "interaction_ack_latency" ## Milliseconds from
    ## interaction receipt to initial acknowledgement.
  interactionAutoDeferTotal* = "interaction_auto_defer_total" ## Counter delta;
    ## record `1` for each automatic defer.
  interactionExpiredTotal* = "interaction_expired_total" ## Counter delta;
    ## record `1` for each expired interaction.
  restRequestLatency* = "rest_request_latency" ## Milliseconds for one REST
    ## request.
  restBucketQueueDelay* = "rest_bucket_queue_delay" ## Timing observation in
    ## milliseconds spent waiting for a REST bucket.
  rest429Total* = "rest_429_total" ## Counter delta; record `1` for each HTTP
    ## 429 response.
  restRetryTotal* = "rest_retry_total" ## Counter delta; record `1` for each
    ## REST retry attempt.
  gatewayHeartbeatRtt* = "gateway_heartbeat_rtt" ## Milliseconds for one
    ## heartbeat round trip.
  gatewaySequenceLag* = "gateway_sequence_lag" ## Gauge in Gateway sequence
    ## positions.
  gatewayReconnectTotal* = "gateway_reconnect_total" ## Counter delta; record
    ## `1` for each reconnect attempt.
  gatewayDispatchQueueDepth* = "gateway_dispatch_queue_depth" ## Gauge in
    ## queued Gateway dispatches.
  handlerDuration* = "handler_duration" ## Milliseconds for one handler
    ## execution.
  handlerQueueDepth* = "handler_queue_depth" ## Gauge in handlers waiting to
    ## run.
  handlerCancelledTotal* = "handler_cancelled_total" ## Counter delta; record
    ## `1` for each cancelled handler.
  cacheHitRatio* = "cache_hit_ratio" ## Gauge in the inclusive range
    ## `0.0 .. 1.0`.
  cacheEntries* = "cache_entries" ## Gauge in retained cache entries.
  voicePacketLoss* = "voice_packet_loss" ## Gauge in the inclusive range
    ## `0.0 .. 1.0`.
  voiceJitter* = "voice_jitter" ## Milliseconds of packet-arrival jitter.
  voiceDecodeDelay* = "voice_decode_delay" ## Milliseconds for audio decoding.

func metricAttribute*(key, value: string): MetricAttribute {.raises: [].} =
  ## Creates one already-redacted metric attribute.
  MetricAttribute(key: key, value: value)

func metricSample*(name: string, value: float64,
                   attributes: openArray[MetricAttribute] = []): MetricSample
    {.raises: [].} =
  ## Creates one observation and copies its attributes without aggregation or
  ## validation.
  MetricSample(name: name, value: value, attributes: @attributes)

proc record*(recorder: MetricRecorder, sample: sink MetricSample) {.raises: [].} =
  ## Forwards exactly one observation; a nil recorder is a no-op.
  if not recorder.isNil:
    recorder(sample)

func standardMetricNames*(): seq[string] =
  ## Returns every stable metric name exposed by the runtime.
  @[
    interactionAckLatency,
    interactionAutoDeferTotal,
    interactionExpiredTotal,
    restRequestLatency,
    restBucketQueueDelay,
    rest429Total,
    restRetryTotal,
    gatewayHeartbeatRtt,
    gatewaySequenceLag,
    gatewayReconnectTotal,
    gatewayDispatchQueueDepth,
    handlerDuration,
    handlerQueueDepth,
    handlerCancelledTotal,
    cacheHitRatio,
    cacheEntries,
    voicePacketLoss,
    voiceJitter,
    voiceDecodeDelay
  ]
