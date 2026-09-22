# Threat model

## Security objective

Assume the coding agent may be destructive, buggy, manipulated by project contents, or simply wrong. It is allowed to be highly autonomous inside its development machine. Safety must come from containing the machine and controlling the crossing points, not from trusting the model's command-approval logic.

The desired failure mode is:

> The agent may destroy one disposable VM. It must not gain authority over the host, real repository history, credentials, or unrelated systems merely because it can execute arbitrary code inside that VM.

## Trusted computing base

This design still has a trusted computing base. It includes:

- macOS/Linux host and hypervisor boundary;
- Docker Sandboxes / `sandboxd` and its host-side policy/credential proxy;
- the `agent-sbx` host controller in this bundle;
- Docker/agent template supply chain used to instantiate the VM;
- the chosen cloud model provider for any project context intentionally sent to it;
- the human operator when granting network access or accepting output.

This is defense-in-depth, not a mathematical proof that a hypervisor or Docker Sandboxes can never contain a vulnerability.

The wrapper requires Docker Sandboxes 0.45.0 or newer. Docker Sandboxes 0.42.0 fixed macOS host-boundary vulnerabilities involving virtio-fs symlinks and Unix-socket relay behavior. 0.45.0 additionally fixed a credential-proxy revocation issue. Staying current remains part of the boundary.

## Agent is intentionally powerful inside the VM

Once explicitly started, the agent may:

- use sudo inside the sandbox;
- modify/delete/create any sandbox file;
- rewrite or destroy the sandbox's synthetic Git repository;
- run package scripts, builds, tests, dev servers, databases, and background processes;
- use the sandbox's private Docker Engine;
- install software when a required destination has been explicitly allowed;
- keep working autonomously until the requested goal is complete.

This is intentional. Agent-level approval prompts are not the primary security boundary.

## Host resources the agent must not receive

The strict profile excludes:

- a host workspace bind mount;
- clone-mode access to the real repository;
- the real `.git` object database, refs, reflogs, hooks, remotes, or Git config;
- host SSH-agent forwarding;
- shared sandbox skills;
- host GitHub credentials;
- AWS credentials / SSO cache;
- npm/registry credentials;
- 1Password sockets;
- the host Docker socket/daemon;
- registered Docker Sandbox MCP servers;
- local host-run MCP servers;
- host home/config directories;
- global Docker Sandbox service secrets.

`agent-sbx harden` disables the applicable shared capabilities. `create` then performs a strict preflight and refuses to continue if SSH forwarding / shared skills / clipboard image reads are not in the expected state or if global Sandbox secrets / MCP registrations are present.

## Workspace boundary

The real repository is never used as a Docker Sandbox workspace.

The controller creates the sandbox **without a workspace path** and copies a sanitized source snapshot into `/home/agent/workspace` afterward. There is therefore no direct or read-only filesystem mount tying the VM's workspace to the real repository.

The input snapshot contains:

- tracked files;
- nonignored untracked files;
- current on-disk working-tree contents, including unstaged source edits;
- no `.git` directory;
- no Git-ignored files;
- no obvious credential files such as `.env`, `.npmrc`, or private-key formats;
- no `.idea`, `.ssh`, `.aws`, or project-local `.config/gh` trees.

Excluded input paths are recorded so omission is visible rather than silent.

Inside the VM, the source is initialized as an unrelated synthetic Git repository with a single deterministic baseline commit/tag. Agent Git operations therefore have no authority over the real repository.

## Clean-state boundary

Docker Sandbox VM state persists across a normal stop/start. `stop` is therefore **not** a reset mechanism.

The intended clean-state sequence is:

1. create the mountless VM from the sanitized source snapshot;
2. prepare dependencies/tooling while the coding agent is still off;
3. save a clean checkpoint before model authentication or agent execution;
4. authenticate and run the agent only afterward.

`reset` destroys the current sandbox. If the clean checkpoint exists, a new sandbox is created from that checkpoint; otherwise it is recreated from the original source snapshot. Sandbox-scoped model credentials die with the deleted VM and must be re-established.

`reject` destroys the sandbox and its per-session checkpoint.

`accept` applies a validated patch and then destroys the sandbox/checkpoint.

`nuke` calls Docker Sandboxes' global reset and removes this controller's state; it is the scorched-earth path that also clears Docker Sandboxes' local image/template cache, policies, secrets, login, and daemon/config state.

A saved checkpoint/template is host-side Docker Sandboxes state. It is intentionally inaccessible to the agent as a host filesystem path, but its bytes do persist locally until accept/reject/removal or global `nuke`.

## Network model

`agent-sbx harden` initializes Docker Sandboxes with a deny-all global network baseline. Built-in agent kits may contribute the specific model-provider connectivity required for the agent to operate.

Any additional destination is host-controlled with `network-allow` / `network-revoke`, or is granted temporarily by `prepare` and removed automatically on exit.

The agent prompt tells the model not to evade blocked network access, but the actual control is the sandbox network policy outside the model process.

### Cloud-model caveat

A cloud coding agent necessarily sends some project context to its model provider. Therefore this design does **not** claim that no project bytes ever leave the machine.

The intended guarantee is narrower and useful:

> The sandbox has no arbitrary outbound path beyond the model-provider traffic supplied by the agent kit and destinations the operator explicitly permits.

If the requirement is that source code never leave the local machine at all, a local model/provider must replace the cloud model.

## Credential model

Provider authentication is configured only after the clean checkpoint and is scoped to the individual sandbox.

Docker Sandboxes' credential proxy keeps managed service-secret values on the host side and injects authentication into matching outbound requests. The raw credential is not written into the sandbox filesystem by this workflow.

Global service secrets are disallowed by default because they broaden the blast radius to future sandboxes. GitHub/AWS/registry credentials are not configured by this wrapper.

SSH agent forwarding is explicitly disabled because even without exposing private-key bytes, a forwarded agent would still grant sandbox processes the ability to request host-backed authentication/signatures.

## Output boundary

The agent does not authoritatively apply its own output to the real repository.

`export` performs a host-controlled copy of the finished workspace, removes the synthetic `.git`, strips protected credential/config paths, overlays the result onto the original sanitized baseline using content checks rather than timestamp/size quick checks, stages only the quarantine comparison tree, and derives a binary-capable Git patch on the host.

This matters for correctness as well as security:

- new agent-created files are included because the quarantine tree is staged before diff generation;
- same-size/same-second file edits are not silently missed because the overlay uses checksum comparison;
- the portable `finished-codebase.tar.gz` is generated from the staged synthetic Git tree rather than the raw runtime filesystem, so ordinary ignored runtime state is not blindly exported as source.

`accept` then:

1. re-snapshots the real host working tree;
2. requires it to match the original sanitized baseline tree exactly;
3. refuses changed symlink or gitlink paths, including edits to an already-existing symlink;
4. refuses `.gitmodules` changes for manual handling;
5. runs `git apply --check`;
6. shows the diffstat and sensitive-path report;
7. requires literal human confirmation `ACCEPT <name>`;
8. applies only to the real working tree.

The accept path does not stage, commit, push, checkout, alter refs, alter remotes, or modify Git configuration.

## Protected-path quarantine

If the agent creates files that look like credentials or host-integration state, export strips them from the automatic deliverable and reports them in `quarantined-paths.txt`.

This is not intended to be a perfect secret classifier. It is a hardening layer on top of the more important boundary: the sandbox should not possess host secrets in the first place.

## MCP, skills, clipboard, and other integration channels

Docker Sandbox MCP is an explicit host integration point. Local stdio MCP servers can execute as host processes, so this strict profile requires the registration list to be empty.

Shared agent skills are disabled rather than mounted from host state.

SSH agent forwarding is disabled.

Clipboard image reads are disabled. Docker Sandboxes can support interactions such as clipboard writes; do not treat the clipboard as a secret storage channel while running untrusted code, and inspect it before pasting sensitive content.

Ports published for application preview should be bound only to loopback through the wrapper's preview command.

## Residual risks

This design does not eliminate:

- a vulnerability in the hypervisor/Docker Sandboxes implementation;
- malicious or compromised base/template/agent images;
- data intentionally sent to the selected cloud model provider;
- data sent to a hostname the operator explicitly allows;
- malicious behavior in output that the human accepts into the real repository;
- supply-chain risk from dependencies intentionally downloaded during `prepare` or later approved network windows;
- denial of service against local CPU/RAM/disk within whatever host resources Docker Sandboxes makes available.

For especially sensitive work, pin and verify the Docker Sandboxes release and template provenance, set explicit CPU/memory limits, use a local model, and treat the exported code exactly like an untrusted external contribution until reviewed and tested.
