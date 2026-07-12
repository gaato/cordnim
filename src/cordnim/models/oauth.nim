## OAuth resource models returned by Discord's authenticated REST endpoints.
##
## This module models authorization, application, OpenID Connect, and public-key
## responses. It does not implement authorization-code or token exchange.

import std/[json, options, sets]

import ./[common, user]

type
  ApplicationType* = enum ## Known Discord application classifications.
    atGuildRoleSubscriptions = 4

  ApplicationExplicitContentFilter* = enum ## Known application content policy.
    aecfInherit = 0
    aecfAlways = 1

  OAuthScope* = enum ## OAuth scopes known by the pinned schema revision.
    osIdentify
    osEmail
    osConnections
    osGuilds
    osGuildsJoin
    osGuildsMembersRead
    osGroupDmJoin
    osBot
    osRpc
    osRpcNotificationsRead
    osRpcVoiceRead
    osRpcVoiceWrite
    osRpcVideoRead
    osRpcVideoWrite
    osRpcScreenshareRead
    osRpcScreenshareWrite
    osRpcActivitiesWrite
    osWebhookIncoming
    osMessagesRead
    osApplicationsBuildsUpload
    osApplicationsBuildsRead
    osApplicationsCommands
    osApplicationsCommandsPermissionsUpdate
    osApplicationsCommandsUpdate
    osApplicationsStoreUpdate
    osApplicationsEntitlements
    osActivitiesRead
    osActivitiesWrite
    osActivitiesInvitesWrite
    osRelationshipsRead
    osVoice
    osDmChannelsRead
    osRoleConnectionsWrite
    osOpenId

  TeamMembershipState* = enum ## Application-team invitation state.
    tmsInvited = 1
    tmsAccepted = 2

  TeamMemberRole* = enum ## Known application-team roles.
    tmrAdmin
    tmrDeveloper
    tmrReadOnly

  ApplicationFlagsDomain* = object ## Type marker for application flag bits.
  ApplicationFlags* = DiscordBits[ApplicationFlagsDomain]

  OAuthInstallParams* = object ## Default scopes and permissions for installs.
    scopes*: seq[OpenEnum[OAuthScope, string]]
    permissions*: Permissions

  Application* = object ## Public application data embedded in OAuth responses.
    id*: ApplicationId
    name*: string
    icon*: Option[string]
    description*: string
    kind*: Option[OpenEnum[ApplicationType, int]]
    verifyKey*: string
    legacyFlags*: int64
    flags*: ApplicationFlags
    primarySkuId*: Option[SkuId]
    guildId*: Option[GuildId]
    bot*: Option[User]
    installParams*: Option[OAuthInstallParams]
    snapshot: DiscordSnapshot

  ApplicationTeamMember* = object ## One member of an application team.
    user*: User
    teamId*: TeamId
    membershipState*: OpenEnum[TeamMembershipState, int]
    role*: OpenEnum[TeamMemberRole, string]
    permissions*: seq[string]
    snapshot: DiscordSnapshot

  ApplicationTeam* = object ## Team that owns a private application.
    id*: TeamId
    icon*: Option[string]
    name*: string
    ownerUserId*: UserId
    members*: seq[ApplicationTeamMember]
    snapshot: DiscordSnapshot

  PrivateApplication* = object ## Application data available to its owner.
    application*: Application
    redirectUris*: seq[string]
    interactionsEndpointUrl*: Option[string]
    roleConnectionsVerificationUrl*: Option[string]
    owner*: User
    approximateGuildCount*: int64
    approximateUserInstallCount*: int64
    approximateUserAuthorizationCount*: int64
    explicitContentFilter*: OpenEnum[ApplicationExplicitContentFilter, int]
    team*: Option[ApplicationTeam]
    snapshot: DiscordSnapshot

  OAuthAuthorization* = object ## Current bearer-token authorization metadata.
    application*: Application
    expires*: Timestamp
    scopes*: seq[OpenEnum[OAuthScope, string]]
    user*: Option[User]
    snapshot: DiscordSnapshot

  OpenIdIdentity* = object ## Claims returned by Discord's OIDC userinfo route.
    subject*: string
    email*: Option[string]
    emailVerified*: Option[bool]
    preferredUsername*: Option[string]
    nickname*: Option[string]
    picture*: Option[string]
    locale*: Option[string]
    snapshot: DiscordSnapshot

  OAuthPublicKey* = object ## One JWK used to verify Discord-issued tokens.
    keyType*: string
    use*: string
    keyId*: string
    modulus*: string
    exponent*: string
    algorithm*: string

  OAuthPublicKeys* = object ## Public JSON Web Key set returned by Discord.
    keys*: seq[OAuthPublicKey]
    snapshot: DiscordSnapshot

const oauthScopeMapping* = [
  ("identify", osIdentify),
  ("email", osEmail),
  ("connections", osConnections),
  ("guilds", osGuilds),
  ("guilds.join", osGuildsJoin),
  ("guilds.members.read", osGuildsMembersRead),
  ("gdm.join", osGroupDmJoin),
  ("bot", osBot),
  ("rpc", osRpc),
  ("rpc.notifications.read", osRpcNotificationsRead),
  ("rpc.voice.read", osRpcVoiceRead),
  ("rpc.voice.write", osRpcVoiceWrite),
  ("rpc.video.read", osRpcVideoRead),
  ("rpc.video.write", osRpcVideoWrite),
  ("rpc.screenshare.read", osRpcScreenshareRead),
  ("rpc.screenshare.write", osRpcScreenshareWrite),
  ("rpc.activities.write", osRpcActivitiesWrite),
  ("webhook.incoming", osWebhookIncoming),
  ("messages.read", osMessagesRead),
  ("applications.builds.upload", osApplicationsBuildsUpload),
  ("applications.builds.read", osApplicationsBuildsRead),
  ("applications.commands", osApplicationsCommands),
  ("applications.commands.permissions.update",
    osApplicationsCommandsPermissionsUpdate),
  ("applications.commands.update", osApplicationsCommandsUpdate),
  ("applications.store.update", osApplicationsStoreUpdate),
  ("applications.entitlements", osApplicationsEntitlements),
  ("activities.read", osActivitiesRead),
  ("activities.write", osActivitiesWrite),
  ("activities.invites.write", osActivitiesInvitesWrite),
  ("relationships.read", osRelationshipsRead),
  ("voice", osVoice),
  ("dm_channels.read", osDmChannelsRead),
  ("role_connections.write", osRoleConnectionsWrite),
  ("openid", osOpenId),
]

const
  teamMemberRoleMapping* = [
    ("admin", tmrAdmin),
    ("developer", tmrDeveloper),
    ("read_only", tmrReadOnly),
  ]
  applicationResponseFields = [
    "id", "name", "icon", "description", "type", "cover_image",
    "primary_sku_id", "bot", "slug", "guild_id", "rpc_origins",
    "bot_public", "bot_require_code_grant", "terms_of_service_url",
    "privacy_policy_url", "custom_install_url", "install_params",
    "integration_types_config", "verify_key", "flags", "flags_new",
    "max_participants", "tags",
  ]

proc requiredNullable(obj: JsonNode; name, owner: string): Option[JsonNode] =
  if not obj.hasKey(name):
    raiseDecode(owner & " is missing required field '" & name & "'")
  if obj[name].kind == JNull:
    none(JsonNode)
  else:
    some(obj[name])

proc optionalStrict(obj: JsonNode; name, owner: string): Option[JsonNode] =
  if not obj.hasKey(name):
    return none(JsonNode)
  if obj[name].kind == JNull:
    raiseDecode(owner & "." & name & " must not be null")
  some(obj[name])

proc nullableString(obj: JsonNode; name, owner: string;
                    required: bool): Option[string] =
  let value = if required:
      requiredNullable(obj, name, owner)
    else:
      optionalField(obj, name)
  if value.isSome:
    some(asString(value.get, owner & "." & name))
  else:
    none(string)

proc strictString(obj: JsonNode; name, owner: string): Option[string] =
  let value = optionalStrict(obj, name, owner)
  if value.isSome:
    some(asString(value.get, owner & "." & name))
  else:
    none(string)

proc decodeScopes(node: JsonNode; context: string):
    seq[OpenEnum[OAuthScope, string]] =
  var seen = initHashSet[string]()
  for item in asArray(node, context):
    let scope = decodeStringEnum(OAuthScope, item, context & "[]")
    if scope.toRaw in seen:
      raiseDecode(context & " must not contain duplicate scopes")
    seen.incl(scope.toRaw)
    result.add(scope)

proc decodeInstallParams(node: JsonNode; context: string): OAuthInstallParams =
  let obj = ensureObject(node, context)
  result.scopes = decodeScopes(requireField(obj, "scopes", context),
    context & ".scopes")
  result.permissions = decodePermissions(
    requireField(obj, "permissions", context), context & ".permissions")

proc decodeApplicationFlags(node: JsonNode; context: string): ApplicationFlags =
  let encoded = asString(node, context)
  try:
    parseDiscordBits[ApplicationFlagsDomain](encoded)
  except ValueError as error:
    raiseDecode(context & ": " & error.msg)

proc decodeApplication*(node: JsonNode): Application =
  ## Decodes a pinned `ApplicationResponse` while retaining future fields.
  let obj = ensureObject(node, "application")
  result.id = decodeId(ApplicationId,
    requireField(obj, "id", "application"), "application.id")
  result.name = asString(requireField(obj, "name", "application"),
    "application.name")
  result.icon = nullableString(obj, "icon", "application", required = true)
  result.description = asString(
    requireField(obj, "description", "application"),
    "application.description")
  let kind = requiredNullable(obj, "type", "application")
  if kind.isSome:
    result.kind = some(decodeIntEnum(ApplicationType, kind.get,
      "application.type"))
  result.verifyKey = asString(
    requireField(obj, "verify_key", "application"),
    "application.verify_key")
  result.legacyFlags = asInt(requireField(obj, "flags", "application"),
    "application.flags")
  if result.legacyFlags < int64(low(int32)) or
      result.legacyFlags > int64(high(int32)):
    raiseDecode("application.flags is outside int32")
  result.flags = decodeApplicationFlags(
    requireField(obj, "flags_new", "application"),
    "application.flags_new")

  let sku = optionalStrict(obj, "primary_sku_id", "application")
  if sku.isSome:
    result.primarySkuId = some(decodeId(SkuId, sku.get,
      "application.primary_sku_id"))
  let guild = optionalStrict(obj, "guild_id", "application")
  if guild.isSome:
    result.guildId = some(decodeId(GuildId, guild.get,
      "application.guild_id"))
  let bot = optionalStrict(obj, "bot", "application")
  if bot.isSome:
    result.bot = some(decodeUser(bot.get))
  let installParams = optionalStrict(obj, "install_params", "application")
  if installParams.isSome:
    result.installParams = some(decodeInstallParams(installParams.get,
      "application.install_params"))

  result.snapshot = initSnapshot(obj, [
    "id", "name", "icon", "description", "type", "verify_key", "flags",
    "flags_new", "primary_sku_id", "guild_id", "bot", "install_params",
  ])

proc parseApplication*(text: string): Application =
  ## Parses an encoded `ApplicationResponse`.
  decodeApplication(parseJsonObject(text, "application"))

proc rawJson*(application: Application): JsonNode =
  ## Returns an owned copy of the application response.
  rawJson(application.snapshot)

proc unknownFields*(application: Application): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(application.snapshot)

proc decodeApplicationTeamMember(node: JsonNode): ApplicationTeamMember =
  let obj = ensureObject(node, "application team member")
  result.user = decodeUser(requireField(obj, "user", "application team member"))
  result.teamId = decodeId(TeamId,
    requireField(obj, "team_id", "application team member"),
    "application team member.team_id")
  result.membershipState = decodeIntEnum(TeamMembershipState,
    requireField(obj, "membership_state", "application team member"),
    "application team member.membership_state")
  result.role = decodeStringEnum(TeamMemberRole,
    requireField(obj, "role", "application team member"),
    "application team member.role")
  for item in asArray(requireField(obj, "permissions",
      "application team member"), "application team member.permissions"):
    result.permissions.add(asString(item,
      "application team member.permissions[]"))
  result.snapshot = initSnapshot(obj,
    ["user", "team_id", "membership_state", "role", "permissions"])

proc decodeApplicationTeam(node: JsonNode): ApplicationTeam =
  let obj = ensureObject(node, "application team")
  result.id = decodeId(TeamId,
    requireField(obj, "id", "application team"), "application team.id")
  result.icon = nullableString(obj, "icon", "application team",
    required = true)
  result.name = asString(requireField(obj, "name", "application team"),
    "application team.name")
  result.ownerUserId = decodeId(UserId,
    requireField(obj, "owner_user_id", "application team"),
    "application team.owner_user_id")
  for member in asArray(requireField(obj, "members", "application team"),
      "application team.members"):
    result.members.add(decodeApplicationTeamMember(member))
  result.snapshot = initSnapshot(obj,
    ["id", "icon", "name", "owner_user_id", "members"])

proc rawJson*(team: ApplicationTeam): JsonNode =
  ## Returns an owned copy of the team response.
  rawJson(team.snapshot)

proc unknownFields*(team: ApplicationTeam): seq[UnknownField] =
  ## Returns owned copies of team properties this projection did not consume.
  unknownFields(team.snapshot)

proc rawJson*(member: ApplicationTeamMember): JsonNode =
  ## Returns an owned copy of the team-member response.
  rawJson(member.snapshot)

proc unknownFields*(member: ApplicationTeamMember): seq[UnknownField] =
  ## Returns owned copies of member properties this projection did not consume.
  unknownFields(member.snapshot)

proc publicApplicationProjection(obj: JsonNode): JsonNode =
  ## Copies only fields that belong to pinned `ApplicationResponse`.
  result = newJObject()
  for name in applicationResponseFields:
    if obj.hasKey(name):
      result[name] = obj[name].copy()

proc decodePrivateApplication*(node: JsonNode): PrivateApplication =
  ## Decodes fields guaranteed by `PrivateApplicationResponse`.
  let obj = ensureObject(node, "private application")
  result.application = decodeApplication(publicApplicationProjection(obj))
  for item in asArray(requireField(obj, "redirect_uris",
      "private application"), "private application.redirect_uris"):
    result.redirectUris.add(asString(item,
      "private application.redirect_uris[]"))
  result.interactionsEndpointUrl = nullableString(obj,
    "interactions_endpoint_url", "private application", required = true)
  result.roleConnectionsVerificationUrl = nullableString(obj,
    "role_connections_verification_url", "private application",
    required = true)
  result.owner = decodeUser(requireField(obj, "owner", "private application"))
  result.approximateGuildCount = asInt(requireField(obj,
    "approximate_guild_count", "private application"),
    "private application.approximate_guild_count")
  result.approximateUserInstallCount = asInt(requireField(obj,
    "approximate_user_install_count", "private application"),
    "private application.approximate_user_install_count")
  result.approximateUserAuthorizationCount = asInt(requireField(obj,
    "approximate_user_authorization_count", "private application"),
    "private application.approximate_user_authorization_count")
  for value in [result.approximateGuildCount,
      result.approximateUserInstallCount,
      result.approximateUserAuthorizationCount]:
    if value < 0:
      raiseDecode("private application approximate counts must be non-negative")
  result.explicitContentFilter = decodeIntEnum(ApplicationExplicitContentFilter,
    requireField(obj, "explicit_content_filter", "private application"),
    "private application.explicit_content_filter")
  if not obj.hasKey("team"):
    raiseDecode("private application is missing required field 'team'")
  if obj["team"].kind != JNull:
    result.team = some(decodeApplicationTeam(obj["team"]))
  result.snapshot = initSnapshot(obj, [
    "id", "name", "icon", "description", "type", "verify_key", "flags",
    "flags_new", "primary_sku_id", "guild_id", "bot", "install_params",
    "redirect_uris", "interactions_endpoint_url",
    "role_connections_verification_url", "owner",
    "approximate_guild_count", "approximate_user_install_count",
    "approximate_user_authorization_count", "explicit_content_filter", "team",
  ])

proc parsePrivateApplication*(text: string): PrivateApplication =
  ## Parses an encoded `PrivateApplicationResponse`.
  decodePrivateApplication(parseJsonObject(text, "private application"))

proc rawJson*(application: PrivateApplication): JsonNode =
  ## Returns an owned copy of the private application response.
  rawJson(application.snapshot)

proc unknownFields*(application: PrivateApplication): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(application.snapshot)

proc decodeOAuthAuthorization*(node: JsonNode): OAuthAuthorization =
  ## Decodes `GET /oauth2/@me` authorization metadata.
  let obj = ensureObject(node, "OAuth authorization")
  result.application = decodeApplication(
    requireField(obj, "application", "OAuth authorization"))
  result.expires = decodeTimestamp(
    requireField(obj, "expires", "OAuth authorization"),
    "OAuth authorization.expires")
  result.scopes = decodeScopes(
    requireField(obj, "scopes", "OAuth authorization"),
    "OAuth authorization.scopes")
  let user = optionalStrict(obj, "user", "OAuth authorization")
  if user.isSome:
    result.user = some(decodeUser(user.get))
  result.snapshot = initSnapshot(obj,
    ["application", "expires", "scopes", "user"])

proc parseOAuthAuthorization*(text: string): OAuthAuthorization =
  ## Parses an encoded OAuth authorization response.
  decodeOAuthAuthorization(parseJsonObject(text, "OAuth authorization"))

proc rawJson*(authorization: OAuthAuthorization): JsonNode =
  ## Returns an owned copy of the authorization response.
  rawJson(authorization.snapshot)

proc unknownFields*(authorization: OAuthAuthorization): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(authorization.snapshot)

proc decodeOpenIdIdentity*(node: JsonNode): OpenIdIdentity =
  ## Decodes Discord's OpenID Connect userinfo response.
  let obj = ensureObject(node, "OpenID identity")
  result.subject = asString(requireField(obj, "sub", "OpenID identity"),
    "OpenID identity.sub")
  if result.subject.len == 0:
    raiseDecode("OpenID identity.sub must not be empty")
  result.email = nullableString(obj, "email", "OpenID identity",
    required = false)
  let verified = optionalStrict(obj, "email_verified", "OpenID identity")
  if verified.isSome:
    result.emailVerified = some(asBool(verified.get,
      "OpenID identity.email_verified"))
  result.preferredUsername = strictString(obj, "preferred_username",
    "OpenID identity")
  result.nickname = nullableString(obj, "nickname", "OpenID identity",
    required = false)
  result.picture = strictString(obj, "picture", "OpenID identity")
  result.locale = strictString(obj, "locale", "OpenID identity")
  result.snapshot = initSnapshot(obj, [
    "sub", "email", "email_verified", "preferred_username", "nickname",
    "picture", "locale",
  ])

proc parseOpenIdIdentity*(text: string): OpenIdIdentity =
  ## Parses an encoded OpenID Connect userinfo response.
  decodeOpenIdIdentity(parseJsonObject(text, "OpenID identity"))

proc rawJson*(identity: OpenIdIdentity): JsonNode =
  ## Returns an owned copy of the OIDC userinfo response.
  rawJson(identity.snapshot)

proc unknownFields*(identity: OpenIdIdentity): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(identity.snapshot)

proc decodeOAuthPublicKey(node: JsonNode): OAuthPublicKey =
  let obj = ensureObject(node, "OAuth public key")
  result.keyType = asString(requireField(obj, "kty", "OAuth public key"),
    "OAuth public key.kty")
  result.use = asString(requireField(obj, "use", "OAuth public key"),
    "OAuth public key.use")
  result.keyId = asString(requireField(obj, "kid", "OAuth public key"),
    "OAuth public key.kid")
  result.modulus = asString(requireField(obj, "n", "OAuth public key"),
    "OAuth public key.n")
  result.exponent = asString(requireField(obj, "e", "OAuth public key"),
    "OAuth public key.e")
  result.algorithm = asString(requireField(obj, "alg", "OAuth public key"),
    "OAuth public key.alg")

proc decodeOAuthPublicKeys*(node: JsonNode): OAuthPublicKeys =
  ## Decodes the JWK set from `GET /oauth2/keys`.
  let obj = ensureObject(node, "OAuth public keys")
  for item in asArray(requireField(obj, "keys", "OAuth public keys"),
      "OAuth public keys.keys"):
    result.keys.add(decodeOAuthPublicKey(item))
  result.snapshot = initSnapshot(obj, ["keys"])

proc parseOAuthPublicKeys*(text: string): OAuthPublicKeys =
  ## Parses an encoded OAuth public-key response.
  decodeOAuthPublicKeys(parseJsonObject(text, "OAuth public keys"))

proc rawJson*(keys: OAuthPublicKeys): JsonNode =
  ## Returns an owned copy of the JWK response.
  rawJson(keys.snapshot)

proc unknownFields*(keys: OAuthPublicKeys): seq[UnknownField] =
  ## Returns owned copies of properties this projection did not consume.
  unknownFields(keys.snapshot)
