# Fuzzing

Each target uses Clang libFuzzer with AddressSanitizer and UndefinedBehavior
Sanitizer. Build and run a bounded target from the repository root:

```fish
nim c --path:src --out:build/fuzz/raw_json fuzz/targets/raw_json.nim
build/fuzz/raw_json fuzz/corpus/raw_json -runs=10000 -max_len=65536
```

For deterministic reproduction without libFuzzer, skip the target config and
enable the standalone driver:

```fish
nim c --skipProjCfg -d:fuzzStandalone --path:src \
  --out:build/fuzz/raw_json-standalone fuzz/targets/raw_json.nim
build/fuzz/raw_json-standalone crash-input
```

Keep minimized regression inputs in the matching corpus after classifying the
failure and adding a normal unit test.
