import std/[assertions, json]

import cordnim/components

block cyclic_component_graph_is_rejected:
  var node = container(textDisplay("before cycle"))
  node.children.add node
  let draft = v2Draft(node)
  let validation = draft.validate()

  doAssert not validation.valid
  var foundCycle = false
  for problem in validation.problems:
    if problem.kind == cpkCycle:
      foundCycle = true
  doAssert foundCycle

  doAssertRaises ValueError:
    discard node.countComponents()

  doAssertRaises ValueError:
    discard node.componentJson()

block shared_subtree_is_not_a_cycle:
  let shared = textDisplay("shared")
  let draft = v2Draft(container(shared, shared))
  let validation = draft.validate()

  doAssert validation.valid
  doAssert draft.toJson()["components"][0]["components"].len == 2
