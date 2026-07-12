## Build identity used by diagnostics and protocol client metadata.
##
## The default build label follows the package version. Deployments may replace
## it with `-d:CordnimBuildLabel=<version>` without changing the Discord schema
## identity. Releases in the 0.1 series do not guarantee API compatibility.

const
  CordnimBuildLabel* {.strdefine.} = "0.1.0"
    ## Human-readable build label. This is not the Discord schema revision.
  CordnimServerIdent* = "cordnim/" & CordnimBuildLabel
    ## Product token used by the embedded interaction HTTP server.
  CordnimDiscordUserAgent* = "DiscordBot (" &
    "https://github.com/gaato/cordnim, " & CordnimBuildLabel & ")"
    ## User-Agent sent by the Discord REST transport.
