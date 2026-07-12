## Gateway v10 transport, sessions, shards, dispatch, cache, and supervision.
##
## This surface exposes explicit async owners. Constructing a URL, policy,
## decoder, runner, or runtime performs no network I/O.

import cordnim/gateway/all

export all

runnableExamples:
  let url = buildGatewayUrl("wss://gateway.discord.gg")
  doAssert url == "wss://gateway.discord.gg?v=10&encoding=json"

  let policy = partitionedPolicy(64, 4)
  doAssert policy.maxConcurrent == 4
