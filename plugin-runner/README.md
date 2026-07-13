# LuminaVault plugin runner

Runs reviewed WebAssembly tools outside the API and Hermes containers. A module exports `memory`, `alloc(i32) -> i32`, and `run(i32, i32) -> i64`; `run` returns the output pointer in the high 32 bits and the JSON output length in the low 32 bits. Input JSON includes `_tool`, which is validated against the reviewed manifest before execution.

The runner exposes no WASI environment, filesystem, sockets, clocks, or process API. It enforces a 10 MB module limit, 64 MiB linear memory, 10 million fuel, a 30 second wall deadline, and 1 MiB input/output limits. Modules may import only the six `luminavault.*_allowed() -> i32` capability checks. Each returns one only when the user granted that exact permission at install time; every other import is rejected.

## Server-mediated capabilities

Reviewed modules never receive database credentials, filesystem access, or a
network socket. To use an installed permission, a module returns an ordinary
JSON object containing `_capabilityRequests`. Its value is a JSON-encoded array:

```json
[
  {
    "id": "request-1",
    "operation": "memory.read",
    "arguments": { "id": "b8a7e98f-932e-47a1-8864-474e772f7738" }
  }
]
```

The API checks every operation against the install's current grants, performs
the operation in the tenant boundary, and invokes the module again with the
original tool input plus `_capabilityResults` (a JSON-encoded result array) and
`_capabilityRound`. Results preserve the request `id` and contain `ok`,
`values`, and a stable `error` code. The module returns its final tool output
without `_capabilityRequests`.

The broker supports `memory.read`, `memory.write`, `vault.read`, `vault.write`,
`network.fetch`, and `output.emit`. Network requests are HTTPS GETs to an exact
reviewed hostname, reject private/reserved targets and redirects, and return a
base64 body. Vault reads and writes use tenant-relative paths. An execution is
limited to four capability rounds (plus one final module invocation), 16
capability requests per round, and 1 MiB brokered values. Memory writes are
limited to 64 KiB. Exceeding a limit fails closed.
