## Build identity used by diagnostics and protocol client metadata.
##
## Cordnim has no assigned release version yet. Development builds report the
## label below instead of turning the Nimble packaging placeholder into a public
## compatibility promise. Release tooling may replace it with
## `-d:CordnimBuildLabel=<version>`.

const
  CordnimBuildLabel* {.strdefine.} = "development"
    ## Human-readable build label. This is not the Discord schema revision.
  CordnimServerIdent* = "cordnim/" & CordnimBuildLabel
    ## Product token used by the embedded interaction HTTP server.
  CordnimDiscordUserAgent* = "DiscordBot (" &
    "https://github.com/gaato/cordnim, " & CordnimBuildLabel & ")"
    ## User-Agent sent by the Discord REST transport.
