import std/strutils

import cordnim/build_info

doAssert CordnimBuildLabel.len > 0
doAssert CordnimServerIdent == "cordnim/" & CordnimBuildLabel
doAssert CordnimDiscordUserAgent.startsWith("DiscordBot (")
doAssert CordnimBuildLabel in CordnimDiscordUserAgent
