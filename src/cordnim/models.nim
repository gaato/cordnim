## Handwritten semantic Discord resource models.
##
## These plain value objects give later high-level REST, typed Gateway events,
## and the cache a stable, named representation of Discord resources.
##
## Resources with materially different Gateway and REST contracts expose two
## decoders. The base `decodeX` follows the context-neutral official Resource
## Object optionality, so Gateway payloads that omit endpoint-only fields (a
## member without `user`, a guild without the `max_*` counts, a channel without
## `flags`) decode without error. The stricter `decodeXResponse` layers the
## pinned OpenAPI endpoint required-field list on top and rejects those
## omissions. This is provided for `User`, `Guild`, `Channel`, and `GuildMember`;
## the other resources keep a single decoder. Every decoder validates the
## nullability and JSON type of the fields it does enforce and rejects malformed
## required data.
##
## Each decoded value retains a private deep-copied JSON snapshot, exposed
## through `rawJson` and `unknownFields`, so fields introduced by future Discord
## revisions are preserved. `Webhook` credentials are the sole exception: its
## `token` and `url` are scrubbed to `[REDACTED]` inside the retained snapshot
## before it is stored, so no snapshot accessor or generic representation reveals
## them and the plaintext survives only in the `token`/`url` `Secret` fields.
## Decoders raise `DecodeError`; the outbound `PollCreate` builder raises
## `ValidationError` on illegal input.
##
## Import this module for the full semantic surface, or a single submodule such
## as `cordnim/models/user` for one resource.

import models/common
import models/user
import models/role
import models/member
import models/poll
import models/channel
import models/guild
import models/message
import models/monetization
import models/oauth
import models/webhook

export common
export user
export role
export member
export poll
export channel
export guild
export message
export monetization
export oauth
export webhook
