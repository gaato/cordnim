## Focused tests for the poll model and the outbound PollCreate builder.

import std/[json, options, strutils, unicode]

import cordnim/models/poll

block decodesPollWithResults:
  let poll = decodePoll(%*{
    "question": {"text": "Best color?"},
    "answers": [
      {"answer_id": 1, "poll_media": {"text": "Red",
        "emoji": {"id": newJNull(), "name": "🔴"}}},
      {"answer_id": 2, "poll_media": {"text": "Blue"}}],
    "expiry": "2026-07-20T00:00:00+00:00",
    "allow_multiselect": true,
    "layout_type": 1,
    "results": {"is_finalized": false,
      "answer_counts": [{"id": 1, "count": 4, "me_voted": true}]}})
  doAssert poll.question.text == some("Best color?")
  doAssert poll.answers.len == 2
  doAssert poll.answers[0].answerId == 1
  doAssert poll.answers[0].pollMedia.emoji.get.name == some("🔴")
  doAssert poll.expiry.isSome
  doAssert poll.allowMultiselect
  doAssert poll.layoutType.knownValue == some(pltDefault)
  doAssert poll.results.isSome
  doAssert poll.results.get.answerCounts[0].count == 4

block decodesPollWithNullExpiryAndOmittedResults:
  # Official overlay: expiry is required-nullable, so `null` maps to `none`;
  # results is optional, so its absence means "unknown results" (also `none`).
  let poll = decodePoll(%*{
    "question": {"text": "Q?"},
    "answers": [{"answer_id": 1, "poll_media": {"text": "A"}}],
    "expiry": newJNull(),
    "allow_multiselect": false,
    "layout_type": 1})
  doAssert poll.expiry.isNone
  doAssert poll.results.isNone

block pollResultsIsOptionalNonNull:
  # results is optional but non-null: an explicit `null` is rejected, unlike the
  # pinned schema's required-nullable reading.
  doAssertRaises DecodeError:
    discard decodePoll(%*{
      "question": {"text": "Q?"},
      "answers": [{"answer_id": 1, "poll_media": {"text": "A"}}],
      "expiry": newJNull(),
      "allow_multiselect": false,
      "layout_type": 1,
      "results": newJNull()})
  # Present results with an empty answer_counts is "known, no votes", distinct
  # from absent results ("unknown").
  let known = decodePoll(%*{
    "question": {"text": "Q?"},
    "answers": [{"answer_id": 1, "poll_media": {"text": "A"}}],
    "expiry": "2026-07-20T00:00:00+00:00",
    "allow_multiselect": false,
    "layout_type": 1,
    "results": {"is_finalized": true, "answer_counts": []}})
  doAssert known.results.isSome
  doAssert known.results.get.answerCounts.len == 0

block pollResultsRequireAnswerCounts:
  # When a results object is present, answer_counts is required and non-null.
  doAssertRaises DecodeError:
    discard decodePoll(%*{
      "question": {"text": "Q?"},
      "answers": [{"answer_id": 1, "poll_media": {"text": "A"}}],
      "expiry": newJNull(),
      "allow_multiselect": false,
      "layout_type": 1,
      "results": {"is_finalized": false}})

block missingRequiredPollFieldsRaise:
  doAssertRaises DecodeError:
    discard decodePoll(%*{"answers": [], "allow_multiselect": false,
      "layout_type": 1, "expiry": newJNull()}) # no question
  doAssertRaises DecodeError:
    discard decodePoll(%*{"question": {"text": "x"},
      "allow_multiselect": false, "layout_type": 1,
      "expiry": newJNull()}) # no answers
  # expiry is a required key even though it may be null; omitting it is rejected.
  doAssertRaises DecodeError:
    discard decodePoll(%*{"question": {"text": "x"},
      "answers": [{"answer_id": 1, "poll_media": {"text": "A"}}],
      "allow_multiselect": false, "layout_type": 1}) # no expiry

block pollCreateValidatesInput:
  # Empty question is rejected.
  doAssertRaises ValidationError:
    discard initPollCreate("", [textAnswer("Yes")])
  # Zero answers is rejected.
  doAssertRaises ValidationError:
    discard initPollCreate("Question?", [])
  # More than ten answers is rejected.
  var many: seq[PollMediaCreate]
  for i in 0 .. 10:
    many.add(textAnswer("Answer " & $i))
  doAssertRaises ValidationError:
    discard initPollCreate("Question?", many)
  # Over-long answer text is rejected.
  doAssertRaises ValidationError:
    discard initPollCreate("Question?", [textAnswer("a".repeat(56))])
  # Out-of-range duration is rejected.
  doAssertRaises ValidationError:
    discard initPollCreate("Question?", [textAnswer("Yes")],
      durationHours = 0)
  doAssertRaises ValidationError:
    discard initPollCreate("Question?", [textAnswer("Yes")],
      durationHours = 1000)
  # Only the default layout wire value is accepted.
  doAssertRaises ValidationError:
    discard initPollCreate("Question?", [textAnswer("Yes")], layoutType = 2)

block pollCreateMeasuresCodePointsNotBytes:
  # A 55-code-point answer of multibyte runes is accepted (220 bytes) while a
  # 56th rune trips the limit. A byte-length check would reject both.
  let ok = initPollCreate("Q?", [textAnswer("あ".repeat(55))])
  doAssert ok.answers.len == 1
  doAssert "あ".repeat(55).runeLen == 55
  doAssertRaises ValidationError:
    discard initPollCreate("Q?", [textAnswer("あ".repeat(56))])
  # The question limit is likewise in code points.
  discard initPollCreate("あ".repeat(300), [textAnswer("Yes")])
  doAssertRaises ValidationError:
    discard initPollCreate("あ".repeat(301), [textAnswer("Yes")])

block pollCreateRejectsInvalidUtf8:
  doAssertRaises ValidationError:
    discard initPollCreate("\xffbad", [textAnswer("Yes")])
  doAssertRaises ValidationError:
    discard initPollCreate("Q?", [textAnswer("\xff")])

block pollCreateRejectsShapelessEmoji:
  # An answer emoji with neither id nor name is rejected.
  let shapeless = PollMediaCreate(
    text: none(string), emoji: some(PartialEmoji()))
  doAssertRaises ValidationError:
    discard initPollCreate("Q?", [shapeless])

block pollCreateEmojiNameLengthInCodePoints:
  # The emoji name limit is 32 code points, not bytes: a 32-rune multibyte name
  # is accepted and a 33rd rune is rejected.
  let name32 = "あ".repeat(32)
  doAssert name32.runeLen == 32
  let ok = initPollCreate("Q?",
    [emojiAnswer("A", PartialEmoji(name: some(name32)))])
  # toJson revalidates and still emits the accepted name.
  doAssert ok.toJson["answers"][0]["poll_media"]["emoji"]["name"].getStr ==
    name32
  doAssertRaises ValidationError:
    discard initPollCreate("Q?",
      [emojiAnswer("A", PartialEmoji(name: some("あ".repeat(33))))])

block pollCreateExposesReadOnlyAccessors:
  let poll = initPollCreate(
    "Best color?", [textAnswer("Red")],
    durationHours = 48, allowMultiselect = true)
  doAssert poll.question == "Best color?"
  doAssert poll.answers.len == 1
  doAssert poll.durationHours == 48
  doAssert poll.allowMultiselect
  doAssert poll.layoutType == 1

block pollCreateSerializesOutbound:
  let poll = initPollCreate(
    "Best color?",
    [textAnswer("Red"), emojiAnswer("Blue",
      PartialEmoji(name: some("🔵")))],
    durationHours = 48,
    allowMultiselect = true)
  let payload = poll.toJson
  doAssert payload["question"]["text"].getStr == "Best color?"
  doAssert payload["answers"].len == 2
  doAssert payload["answers"][0]["poll_media"]["text"].getStr == "Red"
  doAssert payload["answers"][1]["poll_media"]["emoji"]["name"].getStr == "🔵"
  doAssert payload["duration"].getInt == 48
  doAssert payload["allow_multiselect"].getBool
  doAssert payload["layout_type"].getInt == 1

block pollCreateCustomEmojiUsesId:
  let poll = initPollCreate("Q?",
    [emojiAnswer("A", PartialEmoji(id: some(toId(EmojiId, 42'u64))))])
  let media = poll.toJson["answers"][0]["poll_media"]
  doAssert media["emoji"]["id"].getStr == "42"
  doAssert not media["emoji"].hasKey("name")
