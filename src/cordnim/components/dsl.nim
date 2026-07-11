## Compile-time syntax for Components V2 literals.

import std/macros

import ./model
import ./validation

proc callName(node: NimNode): string {.compileTime.} =
  if node.kind in {nnkCall, nnkCommand} and node.len > 0:
    $node[0]
  else:
    ""

proc bodyIndex(node: NimNode): int {.compileTime.} =
  if node.len > 1 and node[^1].kind == nnkStmtList:
    node.len - 1
  else:
    -1

proc childrenOf(node: NimNode): seq[NimNode] {.compileTime.} =
  let index = node.bodyIndex()
  if index >= 0:
    for child in node[index]:
      if child.kind != nnkEmpty:
        result.add child

proc staticCount(node: NimNode): int {.compileTime.} =
  if node.kind == nnkStmtList:
    for child in node:
      result += child.staticCount()
  elif node.kind in {nnkCall, nnkCommand}:
    inc result
    for child in node.childrenOf():
      result += child.staticCount()

proc buildNode(node: NimNode, parent = ""): NimNode {.compileTime.} =
  if node.kind notin {nnkCall, nnkCommand}:
    error("Components V2 DSL expects a component call", node)
  let name = node.callName()
  let nested = node.childrenOf()
  let body = node.bodyIndex()

  proc ordinaryArgs(target: NimNode) =
    for index in 1..<node.len:
      if index != body:
        target.add node[index]

  case name
  of "container", "section", "actions", "mediaGallery":
    let symbol = case name
      of "container": bindSym"container"
      of "section": bindSym"section"
      of "actions": bindSym"actionRow"
      of "mediaGallery": bindSym"mediaGallery"
      else: bindSym"container"
    result = newCall(symbol)
    for child in nested:
      result.add(child.buildNode(name))
  of "text":
    result = newCall(bindSym"textDisplay")
    ordinaryArgs(result)
  of "button":
    result = newCall(bindSym"button")
    ordinaryArgs(result)
  of "thumbnail":
    result = newCall(bindSym"thumbnail")
    ordinaryArgs(result)
  of "separator":
    result = newCall(bindSym"separator")
  of "media":
    if parent != "mediaGallery":
      error("media is legal only inside mediaGallery", node)
    result = newCall(bindSym"mediaItem")
    ordinaryArgs(result)
  of "file":
    result = newCall(bindSym"fileComponent")
    ordinaryArgs(result)
  else:
    error("unknown Components V2 DSL node: " & name, node)

macro v2Message*(body: untyped): untyped =
  ## Compiles a literal Components V2 tree and validates its static size.
  ##
  ## Dynamic builders remain available through `v2Draft` and are checked by
  ## `validate` immediately before transport.
  let count = body.staticCount()
  if count > MaxMessageComponents:
    error(
      "component tree contains " & $count & " components; Discord allows " &
        $MaxMessageComponents,
      body
    )
  result = newCall(bindSym"v2Draft")
  let nodes = if body.kind == nnkStmtList: body else: newStmtList(body)
  for node in nodes:
    if node.kind != nnkEmpty:
      result.add(node.buildNode())
