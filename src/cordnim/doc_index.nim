## Documentation-only root for Cordnim's public modules.
##
## `nimble docs` runs `nim doc --project` once from this module. It is not a
## runtime facade; application code should import `cordnim`, `cordnim/api`,
## `cordnim/models`, or one of the lower-level umbrellas described in the
## package guide.

{.push warning[UnusedImport]: off.}

import cordnim
import cordnim/[api, app, application_manifest, build_info, cache, cli,
  collectors, command_policies, commands, components, core, events, gateway,
  interactions, models, observability, raw, rest, runtime, testing]
import cordnim/app/[gateway_config, gateway_interactions, gateway_runtime]

{.pop.}
