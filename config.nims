## Temporary replacement for a pinned nim-websock 0.4.0 module.
##
## Upstream commit 387a8eb7e961e8fdd3b1a717d36bc53b55e4dc5d
## shadows the decoded close code and includes its two wire bytes in the UTF-8
## close reason. Keep the replacement synchronized with atlas.lock and remove
## it once an upstream release contains the same fix.

patchFile("websock", "session", "vendor/patches/websock/session")
