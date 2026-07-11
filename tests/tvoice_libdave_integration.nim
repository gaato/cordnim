import std/assertions

import cordnim/voice/libdave/raw

when defined(cordnimVoiceLibdave):
  block official_library_loads:
    doAssert daveMaxSupportedProtocolVersion() > 0
else:
  block binding_is_opt_in:
    doAssert not libdaveBindingsEnabled
