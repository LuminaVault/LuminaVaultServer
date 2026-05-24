# Scheduled Delivery Cron Gotchas

Session notes from a repair run where Discord delivery, cron wrappers, and alert detection were entangled.

## What happened
- A cron job was failing with `HTTP Error 403: Forbidden` during Discord send.
- The problematic path was a deliver script that talked to Discord directly instead of letting the delivery layer own transport.
- Another cron job failed because the shell wrapper path did not exist.
- An alert detector intentionally returned exit code `1` when it found a real alert, which is not the same thing as a crash.

## Fix pattern
- Separate detection from delivery.
  - The detector should print the alert payload and use a non-zero exit only to signal alert state when that is part of the contract.
  - The delivery wrapper should treat expected alert exits as success if output exists.
- Prefer a thin compatibility wrapper over changing cron definitions first when the job path is broken.
- Make wrappers resolve script paths by absolute path, not cwd.
- Load Hermes env files from multiple likely locations when the runtime differs from the authoring environment.

## Verification
- Syntax-check patched Python with `python3 -m py_compile`.
- Syntax-check shell wrappers with `bash -n`.
- Run the wrapper once end-to-end in the real runtime environment, not just in the local terminal, before declaring the cron fixed.

## Pitfall
- Do not assume exit code `1` means failure in alert pipelines.
  - Check whether the script contract intentionally uses `1` for "alert present".
  - Only treat it as a failure when there is no valid alert output or the process crashed before producing data.
