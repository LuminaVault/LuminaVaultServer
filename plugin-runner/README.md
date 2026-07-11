# LuminaVault plugin runner

Runs reviewed WebAssembly tools outside the API and Hermes containers. A module exports `memory`, `alloc(i32) -> i32`, and `run(i32, i32) -> i64`; `run` returns the output pointer in the high 32 bits and the JSON output length in the low 32 bits. Input JSON includes `_tool`, which is validated against the reviewed manifest before execution.

The runner exposes no WASI environment, filesystem, sockets, clocks, or process API. It enforces a 10 MB module limit, 64 MiB linear memory, 10 million fuel, a 30 second wall deadline, and 1 MiB input/output limits. Modules may import only the six `luminavault.*_allowed() -> i32` capability checks. Each returns one only when the user granted that exact permission at install time; every other import is rejected.
