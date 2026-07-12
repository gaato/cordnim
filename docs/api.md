# Semantic REST API

`cordnim/api` is the typed layer above the generated HTTP inventory. It accepts
validated request values, chooses authentication and retry behavior per
operation, and decodes successful responses into `cordnim/models` values.
Import `cordnim/raw` when an endpoint or field is not covered here.

## Client lifecycle

A REST client and its concrete HTTP transport have separate owners. Start the
client before use, stop it before closing the transport, and keep both on one
Chronos event loop.

```nim
import std/os

import chronos

import cordnim/api
import cordnim/core/secrets
import cordnim/rest

proc inspectChannel(channelId: ChannelId) {.async.} =
  let token = initSecret[BotToken](getEnv("DISCORD_BOT_TOKEN"))
  let transport = newDiscordHttpTransport(token)
  let client = newChronosRestClient(transport.asRestTransport())
  client.start()
  try:
    let channel = await client.fetchChannel(channelId)
    echo channel.name
  finally:
    await client.stop()
    await transport.close()
```

Do not reuse one scheduler across bot and OAuth bearer identities. Discord's
global rate-limit state belongs to the authenticated subject. Construct a
separate transport and client when the credential identity changes.

## Modules

| Import | Typed operations |
| --- | --- |
| `cordnim/api/applications` | Application resource lookup |
| `cordnim/api/gateway_bootstrap` | Gateway URL, shard count, and session-start limits |
| `cordnim/api/oauth2` | Current authorization, application, public keys, and OpenID identity |
| `cordnim/api/monetization` | Entitlements, SKUs, subscriptions, and test grants |
| `cordnim/api/messages` | Message history, create/edit/delete, reactions, polls, and current pins |
| `cordnim/api/webhooks` | Webhook management, execution, and webhook message edits |
| `cordnim/api/guilds` | Guild settings, roles, bans, bulk bans, and pruning |
| `cordnim/api/members` | Member list/search/add/edit/kick and role assignment |
| `cordnim/api/channels` | Guild channels, overwrites, reorder, typing, and announcement follows |
| `cordnim/api/threads` | Thread creation, archives, membership, and forum starter messages |

The `cordnim/api` umbrella exports all of these modules. Direct imports reduce
name overlap in larger applications.

## Omit, clear, and set

Discord PATCH requests distinguish a missing key from JSON `null`.
`FieldEdit[T]` makes that choice explicit:

```nim
let edit = channelEdit(
  name = editSet("incidents"),
  topic = editClear(string),
  parentId = editOmit(ChannelId)
)

discard await client.editChannel(channelId, edit)
```

`editOmit` leaves the field unchanged, `editClear` writes `null`, and `editSet`
writes a concrete value. A default-constructed `FieldEdit` is omit. Builders
reject an empty edit before it reaches the scheduler.

## Audit reasons and retry behavior

Mutation APIs accept `ApiCallOptions`. The caller may set priority, deadline,
cancellation group, retry bounds, and an audit-log reason. The operation still
owns its idempotency classification.

```nim
let options = initApiCallOptions(
  auditReason = some("remove retired support role")
)
await client.deleteGuildRole(guildId, roleId, options)
```

Safe GET, PUT, DELETE, and repeatable PATCH operations use `idSafe`. Resource
creation, bulk member removal, crossposts, follow-up messages, and other
count-changing POST operations use `idNever` unless the endpoint has a specific
nonce contract. A retry policy cannot turn an `idNever` request into a retryable
one.

Semantic operations also pin their successful status codes. A body-bearing 200
cannot silently stand in for a required 204, and a 204 cannot silently erase a
required response object. Member add and member edit are the documented
exceptions: those APIs return `Option[GuildMember]` for their 201/204 and
200/204 result shapes.

## Authentication boundaries

Bot-owned guild, member, role, channel, thread, message, and management webhook
operations require bot authorization. Webhook-token routes and interaction
callback routes send no `Authorization` header. OAuth identity and current-user
entitlement routes require a bearer transport. Operations that Discord permits
for either bot or bearer credentials declare that alternative explicitly.

`memberAdd` carries a user's OAuth access token inside
`Secret[OAuthBearerToken]`. Its string, representation, `%`, and `jsonutils`
forms are redacted. The plaintext is copied only into the outbound request body.

Member list and search, and expanded thread-member responses, require the
application's `GUILD_MEMBERS` privileged intent. Cordnim documents that
deployment requirement but does not infer or enforce Developer Portal state.

## Permissions and unknown response fields

Outbound role permissions and channel overwrite `allow`/`deny` values are
decimal strings. The backing `Permissions` type is arbitrary-width, so a write
does not truncate a permission bit above 63.

Semantic response models validate known required fields and retain a private,
deep-copied snapshot. `rawJson` returns another copy; `unknownFields` exposes
unconsumed top-level fields. Webhook credentials are scrubbed before their
snapshot is retained.

## Messages, forums, and Components V2

Legacy and Components V2 messages have different generic request types.
Message and webhook handles preserve the mode through edits. A legacy handle
can be upgraded explicitly with `upgradeMessageToV2`; the generated PATCH clears
legacy-only fields and sets the permanent Components V2 flag. There is no
reverse conversion.

Forum thread creation accepts a validated legacy starter-message draft without
file uploads. Multipart message and forum attachments remain raw operations
until the typed API can preserve stream replay, attachment identity, and retry
semantics without weakening those contracts.

## Raw fallback

The semantic layer is intentionally smaller than the 242-operation generated
inventory. Use the raw route when an operation is absent, a new Discord field is
not modeled yet, or multipart support is required. The raw request must still
pass through `toRuntimeRequest` and `ChronosRestClient`; do not bypass the
scheduler or construct token-bearing URLs for logs.

See [rest.md](rest.md) for scheduler ownership and [raw-schema.md](raw-schema.md)
for the generated boundary.
