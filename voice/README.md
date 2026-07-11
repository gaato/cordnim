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
