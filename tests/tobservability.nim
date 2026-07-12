import std/[options, times, unittest]

import cordnim/core/[errors, secrets]
import cordnim/observability/all

func attribute(event: LogEvent; key: string): Option[LogAttribute] =
  for item in event.attributes:
    if item.key == key:
      return some(item)
  none(LogAttribute)

var observedEvents {.threadvar.}: seq[LogEvent]

proc observe(event: LogEvent) {.gcsafe, raises: [].} =
  observedEvents.add event

var observedSamples {.threadvar.}: seq[MetricSample]

proc observeSample(sample: MetricSample) {.gcsafe, raises: [].} =
  observedSamples.add sample

suite "structured observability":
  test "retains typed values and stable event metadata":
    let event = logEvent("gateway.shard.ready", llInfo, [
      logAttribute("shard_id", 2),
      logAttribute("resumed", false),
      logAttribute("latency_ms", 4.5),
    ])
    check event.name == "gateway.shard.ready"
    check event.level == llInfo
    check event.attribute("shard_id").get.value.integerValue == 2
    check not event.attribute("resumed").get.value.booleanValue
    check event.attribute("latency_ms").get.value.floatValue == 4.5

  test "redacts Secret values before handing them to a recorder":
    let token = initSecret[BotToken]("never-log-these-bytes")
    let event = logEvent("rest.auth", llDebug, [
      logAttribute("token", token),
    ])
    check event.attribute("token").get.value.kind == lvString
    check event.attribute("token").get.value.stringValue == redactedSecret

  test "Discord failure events omit exception messages":
    let metadata = initDiscordFailureMeta(
      status = some(429),
      route = some("POST /channels/:channel/messages"),
      retryAfter = some(initDuration(milliseconds = 250)),
      shardId = some(3),
    )
    let error = newDiscordError(
      RateLimitError,
      "sensitive response body must not be copied",
      metadata,
    )
    let event = discordFailureEvent("rest.request.failed", llWarn, error)
    check event.attribute("error_kind").get.value.stringValue == "rate_limit"
    check event.attribute("http_status").get.value.integerValue == 429
    check event.attribute("retry_after_ms").get.value.integerValue == 250
    check event.attribute("shard_id").get.value.integerValue == 3
    for item in event.attributes:
      if item.value.kind == lvString:
        check item.value.stringValue != error.msg

  test "record is a nil-safe, exactly-once handoff":
    observedEvents.setLen(0)
    let recorder: LogRecorder = observe
    recorder.record(logEvent("app.started", llNotice))
    check observedEvents.len == 1
    check observedEvents[0].name == "app.started"

    let absent: LogRecorder = nil
    absent.record(logEvent("ignored", llTrace))
    check observedEvents.len == 1

  test "metric record is a gcsafe, non-raising, nil-safe handoff":
    # Exercises the tightened `{.closure, gcsafe, raises: [].}` MetricRecorder at
    # a live call site: a plain gcsafe/raises:[] sink satisfies the contract.
    observedSamples.setLen(0)
    let recorder: MetricRecorder = observeSample
    recorder.record(metricSample(gatewayHeartbeatRtt, 12.5))
    check observedSamples.len == 1
    check observedSamples[0].name == gatewayHeartbeatRtt
    check observedSamples[0].value == 12.5

    let absent: MetricRecorder = nil
    absent.record(metricSample("ignored", 0.0))
    check observedSamples.len == 1

  test "classifies future DiscordError subtypes without message matching":
    type ApplicationDiscordError = object of DiscordError
    let custom = newDiscordError(ApplicationDiscordError, "custom")
    check custom.kind == dekOther
    check custom.kind.name == "other"
