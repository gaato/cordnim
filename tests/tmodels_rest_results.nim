## Strict semantic result models used by guild/channel/thread REST APIs.

import std/[json, options]

import cordnim/models/[channel, guild]

import ./api_semantic_fixtures

block strict_thread_member_requires_rest_ids:
  let member = decodeThreadMemberResponse(threadMemberJson(withMember = true))
  doAssert member.id == some(ChannelId.parseId("43"))
  doAssert member.userId == some(UserId.parseId("2"))
  doAssert member.member.isSome
  var memberCopy = member.rawJson()
  memberCopy["flags"] = %99
  doAssert member.rawJson()["flags"].getInt() == 0
  var missing = threadMemberJson()
  missing.delete("user_id")
  doAssertRaises DecodeError:
    discard decodeThreadMemberResponse(missing)
  # The context-neutral decoder still accepts an embedded Gateway shape.
  missing.delete("id")
  doAssert decodeThreadMember(missing).userId.isNone

block thread_listing_decodes_first_messages_and_owns_snapshot:
  let listing = decodeThreadListing(threadListingJson(true))
  doAssert listing.threads.len == 1
  doAssert listing.members.len == 1
  doAssert listing.firstMessages.len == 1
  doAssert not listing.hasMore
  var copy = listing.rawJson()
  copy["threads"] = newJArray()
  doAssert listing.rawJson()["threads"].len == 1

block thread_listing_rejects_non_strict_member:
  var listing = threadListingJson()
  listing["members"][0].delete("id")
  doAssertRaises DecodeError:
    discard decodeThreadListing(listing)

block followed_channel_is_typed_and_strict:
  let followed = decodeFollowedChannel(
    %*{"channel_id": "42", "webhook_id": "99"})
  doAssert followed.channelId == ChannelId.parseId("42")
  doAssert followed.webhookId == WebhookId.parseId("99")
  doAssertRaises DecodeError:
    discard decodeFollowedChannel(%*{"channel_id": "42"})

block guild_ban_prune_and_bulk_results_are_strict:
  let ban = decodeBan(banJson())
  doAssert ban.reason == some("spam")
  doAssert ban.user.id == UserId.parseId("3")
  var noReason = banJson()
  noReason.delete("reason")
  doAssertRaises DecodeError:
    discard decodeBan(noReason)

  let noCount = decodeGuildPruneResult(%*{"pruned": nil})
  doAssert noCount.pruned.isNone
  doAssert decodeGuildPruneResult(%*{"pruned": 12}).pruned == some(12'i64)
  doAssertRaises DecodeError:
    discard decodeGuildPruneResult(%*{})

  let bulk = decodeBulkBanResult(
    %*{"banned_users": ["2", "3"], "failed_users": ["4"]})
  doAssert bulk.bannedUsers.len == 2
  doAssert bulk.failedUsers == @[UserId.parseId("4")]
  doAssertRaises DecodeError:
    discard decodeBulkBanResult(%*{"banned_users": []})
