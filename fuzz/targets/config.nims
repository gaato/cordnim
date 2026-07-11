when not defined(fuzzStandalone):
  --cc: clang
  --panics: on
  --define: noSignalHandler
  --define: useMalloc
  --noMain: on
  --passC: "-fsanitize=fuzzer,address,undefined"
  --passL: "-fsanitize=fuzzer,address,undefined"
  --debugger: native
