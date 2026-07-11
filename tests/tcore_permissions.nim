import std/unittest

import cordnim/core

suite "Discord permissions":
  test "queries current known bits without losing future bits":
    var permissions = initDiscordBits[Permission]([
      Permission.sendMessages,
      Permission.useExternalApps,
      Permission.bypassSlowmode
    ])
    permissions.inclBit(80)
    let wire = permissions.toDecimal()
    let decoded = parsePermissions(wire)
    check decoded.contains(Permission.sendMessages)
    check decoded.contains(Permission.useExternalApps)
    check decoded.contains(Permission.bypassSlowmode)
    check decoded.containsBit(80)
    check decoded.unknownBits().containsBit(80)
    check decoded.toDecimal() == wire
