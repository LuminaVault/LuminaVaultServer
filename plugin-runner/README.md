# LuminaVault plugin runner

Runs reviewed WebAssembly tools outside the API and Hermes containers. The v1 ABI is intentionally import-free: a module exports `memory`, `alloc(i32) -> i32`, and `run(i32, i32) -> i64`; `run` returns the output pointer in the high 32 bits and the JSON output length in the low 32 bits.

The runner exposes no WASI environment, filesystem, sockets, clocks, or process API. It enforces a 10 MB module limit, 64 MiB linear memory, 10 million fuel, a 30 second wall deadline, and 1 MiB input/output limits. Capability host functions will be added one at a time behind the server's install grants; unreviewed imports are rejected.
