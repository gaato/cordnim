## Complete generated reference for Cordnim's public modules.
##
## `nimble docs` uses this module to include every documented surface in one
## searchable Nimdoc index. Application code starts with `cordnim` for HTTP
## interactions or adds `cordnim/bot` for a complete Gateway bot. Semantic REST
## operations live in `cordnim/api`; resource values and deterministic test
## support live in `cordnim/models` and `cordnim/testing`.
##
## Cordnim 0.1.0 is a preview. Public APIs may change before a stable release.
## This module exists for documentation generation and is not a runtime facade.

{.push warning[UnusedImport]: off.}

import cordnim
import cordnim/[api, app, application_manifest, bot, build_info, cache, cli,
  collectors, command_policies, commands, components, core, events, gateway,
  interactions, models, observability, raw, rest, runtime, testing]
import cordnim/app/[gateway_config, gateway_interactions, gateway_runtime]
import cordnim/gateway/chronos_runtime

{.pop.}
