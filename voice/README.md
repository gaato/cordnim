# cordnim_voice

Optional Voice Gateway v8 support for cordnim. The package keeps native Voice
dependencies out of the core install.

The `cordnim/voice/libdave/raw` module maps the official libdave v1.1.1 C API.
The declarations are enabled with `-d:cordnimVoiceLibdave` and load libdave at
runtime. The library name can be overridden with
`-d:libdaveLibrary=/path/to/libdave.so`.

No DAVE cryptographic primitive is implemented in Nim. `dave/state` only
coordinates Discord's Voice Gateway transition state around the official
library.

Check the public umbrella and opt-in native declarations, then build both API
references:

```fish
nimble apiCheck
nimble docs
```

The native declarations are compiled and documented without opening the dynamic
library. Generated pages are written under `voice/htmldocs`, separately from the
core API index. Runtime integration tests still require the pinned official
libdave binary.
