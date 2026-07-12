## Semantic models for Discord polls, results, and the outbound poll builder.

import std/[json, options, unicode]

import ./common

export common

const
  MaxPollQuestionLength* = 300 ## Discord's poll question character limit.
  MaxPollAnswerLength* = 55 ## Discord's poll answer text character limit.
  MaxPollEmojiNameLength* = 32 ## Discord's poll answer emoji name limit.
  MinPollAnswers* = 1 ## Fewest answers a poll may offer.
  MaxPollAnswers* = 10 ## Most answers a poll may offer.
  MinPollDurationHours* = 1 ## Shortest poll duration Discord accepts.
  MaxPollDurationHours* = 768 ## Longest poll duration Discord accepts.
  DefaultPollDurationHours* = 24 ## Duration Discord applies when omitted.
  DefaultPollLayout* = 1 ## Default poll layout type wire value.

type
  PollLayoutType* = enum ## Presentation layout of a poll.
    pltDefault = 1 ## The default poll layout.

  PollMedia* = object ## Rendered text and emoji of a poll question or answer.
    text*: Option[string] ## Displayed text, when present.
    emoji*: Option[PartialEmoji] ## Displayed emoji, when present.

  PollAnswer* = object ## One selectable answer within a poll.
    answerId*: int64 ## Stable identifier used by results and vote requests.
    pollMedia*: PollMedia ## Rendered content of the answer.

  PollAnswerCount* = object ## Tallied votes for a single answer.
    id*: int64 ## Answer identifier the count applies to.
    count*: int64 ## Number of votes counted so far.
    meVoted*: bool ## Whether the current user voted for this answer.

  PollResults* = object ## Aggregated vote results of a poll.
    isFinalized*: bool ## Whether counting has completed.
    answerCounts*: seq[PollAnswerCount] ## Per-answer vote tallies.

  Poll* = object ## A decoded Discord poll attached to a message.
    question*: PollMedia ## Rendered poll question.
    answers*: seq[PollAnswer] ## Selectable answers in display order.
    expiry*: Option[Timestamp] ## When voting closes; required but nullable, so
                               ## `none` marks a poll with no scheduled expiry.
    allowMultiselect*: bool ## Whether voters may pick multiple answers.
    layoutType*: OpenEnum[PollLayoutType, int] ## Poll presentation layout.
    results*: Option[PollResults] ## Vote results when reported; `none` means the
                                  ## results are unknown, not that there are no
                                  ## votes.
    snapshot: DiscordSnapshot ## Retained decode evidence for the poll.

  PollMediaCreate* = object ## Rendered content for an outbound poll answer.
    text*: Option[string] ## Answer text, when supplied.
    emoji*: Option[PartialEmoji] ## Answer emoji, when supplied.

  PollCreate* = object ## A validated outbound poll payload.
    ##
    ## Construct with `initPollCreate`, which enforces Discord's cardinality,
    ## length, and encoding limits. The fields are private and exposed only
    ## through read-only accessors, so a constructed value cannot be mutated
    ## into an invalid state; `toJson` also revalidates before serializing.
    question: string ## Poll question text.
    answers: seq[PollMediaCreate] ## Ordered answers offered to voters.
    durationHours: int ## Hours the poll stays open.
    allowMultiselect: bool ## Whether voters may pick multiple answers.
    layoutType: int ## Poll layout type wire value.

proc decodePollMedia*(node: JsonNode; context: string): PollMedia =
  ## Decodes a poll media object carrying optional text and emoji.
  let obj = ensureObject(node, context)
  result.text = optString(obj, "text", context)
  let emoji = optionalField(obj, "emoji")
  if emoji.isSome:
    result.emoji = some(decodePartialEmoji(emoji.get, context & ".emoji"))

proc decodePollAnswer(node: JsonNode): PollAnswer =
  let obj = ensureObject(node, "poll.answer")
  result.answerId = asInt(
    requireField(obj, "answer_id", "poll.answer"), "poll.answer.answer_id")
  result.pollMedia = decodePollMedia(
    requireField(obj, "poll_media", "poll.answer"), "poll.answer.poll_media")

proc decodePollAnswerCount(node: JsonNode): PollAnswerCount =
  let obj = ensureObject(node, "poll.results.answer_count")
  result.id = asInt(requireField(obj, "id", "poll.answer_count"),
    "poll.answer_count.id")
  result.count = asInt(requireField(obj, "count", "poll.answer_count"),
    "poll.answer_count.count")
  result.meVoted = asBool(requireField(obj, "me_voted", "poll.answer_count"),
    "poll.answer_count.me_voted")

proc decodePollResults(node: JsonNode): PollResults =
  let obj = ensureObject(node, "poll.results")
  result.isFinalized = asBool(
    requireField(obj, "is_finalized", "poll.results"),
    "poll.results.is_finalized")
  # The official Poll Resource lists `answer_counts` without a `?`, so once a
  # results object exists the array is required and non-null. An empty array
  # means every answer has zero votes, which is distinct from unknown results
  # (an absent `results` object on the poll).
  for countNode in asArray(
      requireField(obj, "answer_counts", "poll.results"),
      "poll.results.answer_counts"):
    result.answerCounts.add(decodePollAnswerCount(countNode))

proc decodePoll*(node: JsonNode): Poll =
  ## Decodes a full Discord poll object, rejecting missing required fields.
  let obj = ensureObject(node, "poll")
  result.question = decodePollMedia(
    requireField(obj, "question", "poll"), "poll.question")
  for answerNode in asArray(
      requireField(obj, "answers", "poll"), "poll.answers"):
    result.answers.add(decodePollAnswer(answerNode))
  # Semantic overlay: the pinned OpenAPI marks `expiry` and `results` required
  # and non-null, but the official Poll Resource is authoritative on wire
  # behaviour and describes `expiry` as required *nullable* (nullable to allow
  # future non-expiring polls) and `results` as *optional*, where absence means
  # "unknown results" rather than "no results". This decoder follows the
  # official contract: `expiry` must be present but may be `null`, and `results`
  # may be omitted (`none`) but, when present, must not be `null`.
  result.expiry = reqNullableTimestamp(obj, "expiry", "poll")
  result.allowMultiselect = asBool(
    requireField(obj, "allow_multiselect", "poll"), "poll.allow_multiselect")
  result.layoutType = decodeIntEnum(PollLayoutType,
    requireField(obj, "layout_type", "poll"), "poll.layout_type")
  let results = optionalNonNullField(obj, "results", "poll")
  if results.isSome:
    result.results = some(decodePollResults(results.get))
  result.snapshot = initSnapshot(obj, [
    "question", "answers", "expiry", "allow_multiselect", "layout_type",
    "results"])

proc parsePoll*(text: string): Poll =
  ## Decodes a Discord poll from a JSON document string.
  decodePoll(parseJsonObject(text, "poll"))

proc rawJson*(poll: Poll): JsonNode =
  ## Returns an independent deep copy of the poll's original JSON.
  rawJson(poll.snapshot)

proc unknownFields*(poll: Poll): seq[UnknownField] =
  ## Returns deep copies of poll fields not consumed by the decoder.
  unknownFields(poll.snapshot)

func textAnswer*(text: string): PollMediaCreate =
  ## Builds a text-only outbound poll answer.
  PollMediaCreate(text: some(text), emoji: none(PartialEmoji))

func emojiAnswer*(text: string; emoji: PartialEmoji): PollMediaCreate =
  ## Builds an outbound poll answer with both text and an emoji.
  PollMediaCreate(text: some(text), emoji: some(emoji))

proc validatePollText(value, label: string; limit: int) =
  ## Validates one poll text field: valid UTF-8, non-empty, within the
  ## code-point limit. Length is measured in Unicode code points, not bytes.
  if value.validateUtf8 != -1:
    raise newDiscordError(ValidationError, label & " must be valid UTF-8")
  if value.len == 0:
    raise newDiscordError(ValidationError, label & " must not be empty")
  if value.runeLen > limit:
    raise newDiscordError(ValidationError,
      label & " exceeds " & $limit & " characters")

proc validatePollEmoji(emoji: PartialEmoji) =
  ## Validates a poll answer emoji's shape: it must identify either a custom
  ## emoji by id or a unicode emoji by a valid, non-empty name.
  if emoji.id.isNone and emoji.name.isNone:
    raise newDiscordError(ValidationError,
      "poll answer emoji must have an id or a name")
  if emoji.name.isSome:
    let name = emoji.name.get
    if name.len == 0:
      raise newDiscordError(ValidationError,
        "poll answer emoji name must not be empty")
    if name.validateUtf8 != -1:
      raise newDiscordError(ValidationError,
        "poll answer emoji name must be valid UTF-8")
    # Discord caps the emoji name at 32 code points; measure in runes, not
    # bytes, so unicode emoji are not rejected by their byte length.
    if name.runeLen > MaxPollEmojiNameLength:
      raise newDiscordError(ValidationError,
        "poll answer emoji name exceeds " & $MaxPollEmojiNameLength &
        " characters")

proc validatePollCreate(question: string; answers: openArray[PollMediaCreate];
    durationHours, layoutType: int) =
  ## Enforces every PollCreate invariant, raising `ValidationError` on breach.
  validatePollText(question, "poll question", MaxPollQuestionLength)
  if answers.len < MinPollAnswers:
    raise newDiscordError(ValidationError, "poll must offer at least one answer")
  if answers.len > MaxPollAnswers:
    raise newDiscordError(ValidationError,
      "poll must not exceed " & $MaxPollAnswers & " answers")
  for answer in answers:
    if answer.text.isNone and answer.emoji.isNone:
      raise newDiscordError(ValidationError,
        "poll answer must carry text or an emoji")
    if answer.text.isSome:
      validatePollText(answer.text.get, "poll answer text", MaxPollAnswerLength)
    if answer.emoji.isSome:
      validatePollEmoji(answer.emoji.get)
  if durationHours < MinPollDurationHours or
      durationHours > MaxPollDurationHours:
    raise newDiscordError(ValidationError,
      "poll duration must be between " & $MinPollDurationHours & " and " &
      $MaxPollDurationHours & " hours")
  if layoutType != DefaultPollLayout:
    raise newDiscordError(ValidationError,
      "poll layout type must be " & $DefaultPollLayout)

proc initPollCreate*(question: string; answers: openArray[PollMediaCreate];
    durationHours = DefaultPollDurationHours; allowMultiselect = false;
    layoutType = DefaultPollLayout): PollCreate =
  ## Builds a poll payload, raising `ValidationError` for illegal input.
  ##
  ## Enforces valid UTF-8 and Discord's code-point length limits on the
  ## question and answers, the one-to-ten answer count, each answer's emoji
  ## shape, and the accepted duration and layout ranges.
  validatePollCreate(question, answers, durationHours, layoutType)
  PollCreate(
    question: question,
    answers: @answers,
    durationHours: durationHours,
    allowMultiselect: allowMultiselect,
    layoutType: layoutType)

func question*(poll: PollCreate): string {.inline.} =
  ## Returns the validated poll question text.
  poll.question

func answers*(poll: PollCreate): seq[PollMediaCreate] {.inline.} =
  ## Returns a copy of the validated answers, preserving order.
  poll.answers

func durationHours*(poll: PollCreate): int {.inline.} =
  ## Returns the validated poll duration in hours.
  poll.durationHours

func allowMultiselect*(poll: PollCreate): bool {.inline.} =
  ## Returns whether voters may select multiple answers.
  poll.allowMultiselect

func layoutType*(poll: PollCreate): int {.inline.} =
  ## Returns the poll layout type wire value.
  poll.layoutType

proc emojiToJson(emoji: PartialEmoji): JsonNode =
  result = newJObject()
  if emoji.id.isSome:
    result["id"] = newJString($emoji.id.get)
  elif emoji.name.isSome:
    result["name"] = newJString(emoji.name.get)

proc mediaToJson(media: PollMediaCreate): JsonNode =
  result = newJObject()
  if media.text.isSome:
    result["text"] = newJString(media.text.get)
  if media.emoji.isSome:
    result["emoji"] = emojiToJson(media.emoji.get)

proc toJson*(poll: PollCreate): JsonNode =
  ## Serializes a validated poll into its outbound message-payload JSON.
  ##
  ## Revalidates every invariant first, so serialization can never emit a
  ## payload that violates Discord's poll constraints.
  validatePollCreate(poll.question, poll.answers, poll.durationHours,
    poll.layoutType)
  result = newJObject()
  result["question"] = %*{"text": poll.question}
  var answers = newJArray()
  for answer in poll.answers:
    answers.add(%*{"poll_media": mediaToJson(answer)})
  result["answers"] = answers
  result["duration"] = newJInt(poll.durationHours)
  result["allow_multiselect"] = newJBool(poll.allowMultiselect)
  result["layout_type"] = newJInt(poll.layoutType)
