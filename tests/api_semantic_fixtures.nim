## Shared strict JSON fixtures for semantic REST tests.

import std/json

proc userJson*(id = "2"; username = "cord"): JsonNode =
  %*{
    "id": id, "username": username, "avatar": nil, "discriminator": "0",
    "public_flags": 0, "flags": 0, "global_name": nil,
    "primary_guild": nil,
  }

proc roleJson*(id = "9"): JsonNode =
  %*{
    "id": id, "name": "Operators", "color": 3447003,
    "colors": {"primary_color": 3447003, "secondary_color": nil,
      "tertiary_color": nil},
    "hoist": true, "position": 5, "permissions": "11264",
    "managed": false, "mentionable": true, "icon": nil,
    "unicode_emoji": nil, "flags": 0,
  }

proc guildJson*(id = "7"): JsonNode =
  %*{
    "id": id, "name": "Test Guild", "icon": nil, "description": nil,
    "home_header": nil, "splash": nil, "discovery_splash": nil,
    "features": ["COMMUNITY"], "banner": nil, "owner_id": "2",
    "application_id": nil, "region": "us-east", "afk_channel_id": nil,
    "afk_timeout": 300, "system_channel_id": nil,
    "system_channel_flags": 0, "widget_enabled": false,
    "widget_channel_id": nil, "verification_level": 1,
    "roles": [roleJson()], "default_message_notifications": 1,
    "mfa_level": 0, "explicit_content_filter": 2,
    "max_presences": nil, "max_members": 250000,
    "max_stage_video_channel_users": 50, "max_video_channel_users": 25,
    "vanity_url_code": nil, "premium_tier": 0,
    "premium_subscription_count": 0, "preferred_locale": "en-US",
    "rules_channel_id": nil, "safety_alerts_channel_id": nil,
    "public_updates_channel_id": nil,
    "premium_progress_bar_enabled": false, "nsfw": false,
    "nsfw_level": 0, "emojis": [], "stickers": [],
    "incidents_data": nil,
  }

proc memberJson*(id = "2"): JsonNode =
  %*{
    "user": userJson(id), "nick": "Cord", "avatar": nil, "banner": nil,
    "roles": ["9"], "joined_at": "2026-07-01T00:00:00Z",
    "premium_since": nil, "deaf": false, "mute": false, "flags": 0,
    "pending": false, "communication_disabled_until": nil,
  }

proc channelJson*(id = "42"): JsonNode =
  %*{
    "id": id, "type": 0, "flags": 0, "guild_id": "7",
    "name": "general", "position": 1, "nsfw": false,
    "permission_overwrites": [],
  }

proc threadJson*(id = "43"): JsonNode =
  %*{
    "id": id, "type": 11, "flags": 0, "guild_id": "7",
    "parent_id": "42", "name": "topic", "owner_id": "2",
    "message_count": 1, "member_count": 1, "total_message_sent": 1,
    "thread_metadata": {
      "archived": false, "auto_archive_duration": 1440,
      "archive_timestamp": "2026-07-12T00:00:00Z", "locked": false,
      "create_timestamp": "2026-07-12T00:00:00Z",
    },
  }

proc threadMemberJson*(threadId = "43"; userId = "2";
                       withMember = false): JsonNode =
  result = %*{
    "id": threadId, "user_id": userId,
    "join_timestamp": "2026-07-12T00:00:00Z", "flags": 0,
  }
  if withMember:
    result["member"] = memberJson(userId)

proc messageJson*(id = "100"; channelId = "42"): JsonNode =
  %*{
    "id": id, "channel_id": channelId, "author": userJson(),
    "content": "hello", "timestamp": "2026-07-12T00:00:00Z",
    "edited_timestamp": nil, "tts": false, "mention_everyone": false,
    "mentions": [], "mention_roles": [], "attachments": [], "embeds": [],
    "pinned": false, "type": 0, "flags": 0, "components": [],
  }

proc threadListingJson*(includeFirstMessage = false): JsonNode =
  result = %*{
    "threads": [threadJson()], "members": [threadMemberJson()],
    "has_more": false,
  }
  if includeFirstMessage:
    result["first_messages"] = %*[messageJson(channelId = "43")]

proc banJson*(): JsonNode =
  %*{"reason": "spam", "user": userJson("3", "banned")}
