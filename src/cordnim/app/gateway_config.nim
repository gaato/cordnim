## Application-aware construction of static Gateway shard-runner settings.
##
## Transport factories, coordination, clocks, sleepers, jitter, and dispatch
## remain explicit runtime dependencies. This module only connects immutable
## app subscriptions and `/gateway/bot` bootstrap data to IDENTIFY settings.

import cordnim/app
import cordnim/api/gateway_bootstrap
import cordnim/core/secrets
import cordnim/gateway/[compression, payloads, session, shard_runner, sharding]

const
  DefaultGatewayHelloTimeoutMs* = 20_000'i64
    ## Default maximum wait for HELLO after a connection opens.
  DefaultGatewayLeaseRenewIntervalMs* = 30_000'i64
    ## Default requested cadence for checking a shard lease.
  DefaultGatewayReconnectBackoffMs* = 1_000'i64
    ## Default base delay before reconnecting a failed connection.

type
  GatewayRunnerTuning* = object ## Non-protocol runner timing and compression.
    compression*: GatewayCompression ## Discord transport compression mode.
    helloTimeoutMs*: int64 ## Positive HELLO timeout.
    leaseRenewIntervalMs*: int64 ## Positive requested lease-check cadence.
    reconnectBackoffMs*: int64 ## Non-negative reconnect backoff.

func defaultGatewayRunnerTuning*(): GatewayRunnerTuning =
  ## Returns conservative process-local runner defaults.
  GatewayRunnerTuning(
    compression: gatewayCompressionZlibStream,
    helloTimeoutMs: DefaultGatewayHelloTimeoutMs,
    leaseRenewIntervalMs: DefaultGatewayLeaseRenewIntervalMs,
    reconnectBackoffMs: DefaultGatewayReconnectBackoffMs
  )

proc gatewayShardConfig*(
    config: AppConfig;
    bootstrap: GatewayBotInfo;
    plan: ShardPlan;
    shardId: ShardId;
    token: Secret[BotToken];
    identifyProperties: GatewayIdentifyProperties;
    tuning = defaultGatewayRunnerTuning(),
): GatewayShardRunnerConfig =
  ## Builds one runner's immutable settings from the application declaration.
  ##
  ## The shard must belong to this process's plan. The configured event intents
  ## become the exact IDENTIFY bit mask; Gateway interaction ingress adds no
  ## synthetic intent. Runtime dependencies are still passed separately to
  ## `newGatewayShardRunner`.
  if not config.requiresGatewayConnection():
    raise newException(ValueError,
      "Gateway shard configuration requires Gateway ingress or events")
  if token.isEmpty:
    raise newException(ValueError, "Gateway bot token must not be empty")
  if tuning.helloTimeoutMs <= 0 or tuning.leaseRenewIntervalMs <= 0:
    raise newException(ValueError,
      "Gateway runner timeouts must be greater than zero")
  if tuning.reconnectBackoffMs < 0:
    raise newException(ValueError,
      "Gateway reconnect backoff must not be negative")
  let rawShard = shardId.toUint16
  if rawShard < plan.owned.first or rawShard >= plan.owned.lastExclusive:
    raise newException(ValueError,
      "Gateway shard does not belong to this process plan")

  GatewayShardRunnerConfig(
    shardId: shardId,
    totalShards: plan.totalShards,
    token: token,
    identifyProperties: identifyProperties,
    intents: config.gatewayIntentMask,
    initialUrl: bootstrap.url,
    compression: tuning.compression,
    helloTimeoutMs: tuning.helloTimeoutMs,
    leaseRenewIntervalMs: tuning.leaseRenewIntervalMs,
    reconnectBackoffMs: tuning.reconnectBackoffMs
  )
