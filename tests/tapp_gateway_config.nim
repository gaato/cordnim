## Application-to-Gateway shard configuration tests.

import std/[json, unittest]

import cordnim/app
import cordnim/app/gateway_config
import cordnim/api/gateway_bootstrap
import cordnim/core/secrets
import cordnim/gateway/[compression, payloads, session, sharding]

let bootstrap = decodeGatewayBotInfo(%*{
  "url": "wss://gateway.discord.gg/",
  "shards": 4,
  "session_start_limit": {
    "total": 100,
    "remaining": 90,
    "reset_after": 60_000,
    "max_concurrency": 2
  }
})

suite "Application Gateway configuration":
  test "carries app intents and bootstrap URL into an owned shard":
    let config = initAppConfig(
      ingressHttp,
      gatewaySubscriptions({giGuilds, giGuildMessages, giMessageContent})
    )
    let plan = planShards(4, processIndex = 1, processCount = 2)
    let runner = gatewayShardConfig(
      config,
      bootstrap,
      plan,
      ShardId(2),
      initSecret[BotToken]("secret"),
      initGatewayIdentifyProperties("linux", "cordnim", "cordnim")
    )
    check runner.shardId == ShardId(2)
    check runner.totalShards == 4
    check runner.initialUrl == "wss://gateway.discord.gg/"
    check runner.intents == config.gatewayIntentMask
    check runner.compression == gatewayCompressionZlibStream

  test "interaction-only Gateway ingress uses the zero intent mask":
    let config = initAppConfig(ingressGateway)
    let plan = planShards(4, processIndex = 0, processCount = 1)
    let runner = gatewayShardConfig(
      config,
      bootstrap,
      plan,
      ShardId(0),
      initSecret[BotToken]("secret"),
      initGatewayIdentifyProperties("linux", "cordnim", "cordnim")
    )
    check runner.intents == 0'u64

  test "rejects webhook-only apps and shards outside the process plan":
    let plan = planShards(4, processIndex = 0, processCount = 2)
    expect ValueError:
      discard gatewayShardConfig(
        initAppConfig(ingressHttp),
        bootstrap,
        plan,
        ShardId(0),
        initSecret[BotToken]("secret"),
        initGatewayIdentifyProperties("linux", "cordnim", "cordnim")
      )
    expect ValueError:
      discard gatewayShardConfig(
        initAppConfig(ingressGateway),
        bootstrap,
        plan,
        ShardId(3),
        initSecret[BotToken]("secret"),
        initGatewayIdentifyProperties("linux", "cordnim", "cordnim")
      )
