# nim-websock compatibility patch

`session.nim` is copied from `status-im/nim-websock` commit
`387a8eb7e961e8fdd3b1a717d36bc53b55e4dc5d`, pinned in `atlas.lock`. The copy
is distributed under the upstream MIT option in `LICENSE-MIT`.

The replacement stores the decoded close status, excludes the two status bytes
from the UTF-8 reason, validates reasons regardless of the preceding frame,
echoes an empty close without putting sentinel 1005 on the wire, and rejects
the forbidden wire status 1015.

`config.nims` applies the replacement at compile time. Remove this directory
and the `patchFile` call after the pinned upstream version includes the fix.
