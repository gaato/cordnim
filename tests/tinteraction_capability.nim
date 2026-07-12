import std/unittest

import cordnim/interactions
import cordnim/rest/request

suite "typed interaction response capability":
  test "fresh reply claim commits to a responded capability":
    var interaction = freshInteraction(ikApplicationCommand, MonoMillis(1_000))
    var transition = beginReply(move interaction, MonoMillis(1_100))
    check transition.ok
    var pending = move transition.pending
    let responded = commit(move pending)
    check responded.canFollowup(MonoMillis(1_200)).ok

  test "interaction kind rejects an impossible defer policy":
    var interaction = freshInteraction(ikAutocomplete, MonoMillis(1_000))
    let transition = beginDefer(move interaction, MonoMillis(1_100))
    check not transition.ok
    check transition.error == irePolicyUnsupported

  test "ambiguous transport state retains immutable deadlines":
    var interaction = freshInteraction(ikApplicationCommand, MonoMillis(1_000))
    var transition = beginReply(move interaction, MonoMillis(1_100))
    var pending = move transition.pending
    let unknown = markTransportUnknown(move pending)
    check unknown.deadlines.ackDeadline == MonoMillis(4_000)

  test "autocomplete and update transitions have explicit typed entry points":
    var autocomplete = freshInteraction(ikAutocomplete, MonoMillis(1_000))
    let autocompleteTransition = beginAutocomplete(
      move autocomplete, MonoMillis(1_100))
    check autocompleteTransition.ok

    var commandModal = freshInteraction(
      ikCommandModalSubmit, MonoMillis(1_000))
    let rejected = beginDeferredUpdate(move commandModal, MonoMillis(1_100))
    check not rejected.ok
    check rejected.error == irePolicyUnsupported

    var componentModal = freshInteraction(
      ikComponentModalSubmit, MonoMillis(1_000))
    let accepted = beginUpdate(move componentModal, MonoMillis(1_100))
    check accepted.ok
