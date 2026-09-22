# Validation notes

The bundle was validated in two layers before packaging.

## Static validation

- `bash -n bin/agent-sbx` passes.
- The controller is intentionally written without Bash-4-only associative arrays/readarray features so it remains compatible with the older Bash family commonly present on macOS.
- The generated package preserves `bin/agent-sbx` as executable.

## Simulated lifecycle integration test

A temporary fake `sbx` backend was used to exercise the host-controller logic without pretending that a real microVM was available in the build environment.

The test covered:

1. create a normal Git repository with:
   - tracked source;
   - a tracked `.env` containing a host secret;
   - `.gitignore` excluding `node_modules`;
2. create a sanitized session;
3. simulate agent behavior that:
   - modifies an existing source file;
   - creates a brand-new source file;
   - creates ignored runtime state under `node_modules`;
   - creates a sandbox `.env`;
4. export the result and verify:
   - the existing-file edit is in the patch;
   - the new file is in the patch;
   - the protected `.env` is quarantined;
   - ignored `node_modules` content is absent from `finished-codebase.tar.gz`;
5. accept and verify:
   - source edits appear in the real working tree;
   - the real host `.env` is unchanged;
   - the controller does not require staging/committing the result;
6. checkpoint a prepared sandbox, deliberately poison/destroy its working state, reset it, and verify the prepared checkpoint state returns while the poison does not;
7. reject the reset session and verify its per-session state/checkpoint are removed;
8. modify the target of a symlink that already existed in the baseline and verify `accept` refuses automatic application.

The test passed.

Two correctness bugs were found during earlier controller testing and fixed before this package was finalized:

- using an unstaged diff omitted brand-new agent-created files; export now stages only the quarantine comparison tree and diffs the index;
- ordinary rsync quick-check semantics could miss a same-size modification made within the same timestamp granularity; the quarantine overlay now uses checksum comparison.

## What was not claimed

This validation does **not** claim that a real Docker Sandboxes microVM was launched in this build environment. Before trusting the setup on a real workstation, run:

```bash
agent-sbx harden
agent-sbx doctor
```

and do one sacrificial test repository through the full `create -> prepare -> checkpoint -> auth -> run -> export -> reject` lifecycle before using it on important work.

The security boundary ultimately depends on the installed Docker Sandboxes release and its hypervisor/proxy implementation; keep it at or above the minimum pinned in `config/defaults.env` and current with Docker security releases.
