## Stable metric names and transport-neutral metric recording contracts.

type
  MetricAttribute* = object ## One low-cardinality metric attribute.
    key*: string            ## Attribute key.
    value*: string          ## Redacted attribute value.

  MetricSample* = object ## One counter, gauge, or timing observation.
    name*: string                    ## Stable library metric name.
    value*: float64                  ## Observed numeric value.
    attributes*: seq[MetricAttribute] ## Low-cardinality dimensions.

  MetricRecorder* = proc (sample: MetricSample) {.closure.}
    ## Adapter implemented by an application or telemetry integration.

const
  interactionAckLatency* = "interaction_ack_latency" ## Initial ACK latency.
  interactionAutoDeferTotal* = "interaction_auto_defer_total" ## Auto-defer.
  interactionExpiredTotal* = "interaction_expired_total" ## Expired count.
  restRequestLatency* = "rest_request_latency" ## REST request latency.
  restBucketQueueDelay* = "rest_bucket_queue_delay" ## REST bucket queue delay.
  rest429Total* = "rest_429_total" ## REST HTTP 429 count.
  restRetryTotal* = "rest_retry_total" ## REST retry count.
  gatewayHeartbeatRtt* = "gateway_heartbeat_rtt" ## Gateway heartbeat RTT.
  gatewaySequenceLag* = "gateway_sequence_lag" ## Sequence processing lag.
  gatewayReconnectTotal* = "gateway_reconnect_total" ## Gateway reconnect count.
  gatewayDispatchQueueDepth* = "gateway_dispatch_queue_depth" ## Queue depth.
  handlerDuration* = "handler_duration" ## Handler execution duration.
  handlerQueueDepth* = "handler_queue_depth" ## Waiting handler count.
  handlerCancelledTotal* = "handler_cancelled_total" ## Cancelled handler count.
  cacheHitRatio* = "cache_hit_ratio" ## Cache hit ratio.
  cacheEntries* = "cache_entries" ## Cache entry count.
  voicePacketLoss* = "voice_packet_loss" ## Voice packet loss ratio.
  voiceJitter* = "voice_jitter" ## Voice packet-arrival jitter.
  voiceDecodeDelay* = "voice_decode_delay" ## Voice decode delay.

func metricAttribute*(key, value: string): MetricAttribute =
  ## Creates one already-redacted metric attribute.
  MetricAttribute(key: key, value: value)

func metricSample*(name: string, value: float64,
                   attributes: openArray[MetricAttribute] = []): MetricSample =
  ## Creates a metric sample while copying the short attribute list.
  MetricSample(name: name, value: value, attributes: @attributes)

proc record*(recorder: MetricRecorder, sample: sink MetricSample) =
  ## Records a sample when an adapter is configured; nil is a no-op.
  if recorder != nil:
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
