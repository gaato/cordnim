## Public command declaration, compilation, dispatch, and manifest API.

import chronos
import cordnim/commands/[macros, manifest, pragmas, spec]

export chronos, macros, manifest, pragmas
export spec except dispatchWithServices
