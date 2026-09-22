# Disposable autonomous coding-agent sandbox

This is the version where the **agent is allowed to be autonomous** and the **environment is not**.

The goal is not to make Codex or Claude ask permission before every edit or command. The goal is to put the agent in a disposable local microVM where it can run the project, edit freely, use sudo, build/test/start services, use a private Docker Engine, and keep working until the goal is complete — while having no authoritative path back to your real repo, Git history, credentials, or host configuration.

The trust model is:

```text
YOUR MAC
  real repo + real .git + credentials + SSH agent + host Docker
       |
       | host-controlled sanitized COPY (never a mount)
       v
+------------------------------------------------------------------+
| disposable Docker Sandbox microVM                               |
|                                                                  |
| /home/agent/workspace                                            |
|   independent copy of current source                             |
|   synthetic one-commit .git                                      |
|                                                                  |
| coding agent                                                     |
|   full autonomy inside VM                                        |
|   sudo                                                           |
|   yarn/npm/pnpm/build/test/start                                 |
|   private Docker Engine                                          |
|   can wreck the VM; that is acceptable                           |
|                                                                  |
| network                                                          |
|   deny-by-default host policy                                    |
|   model-provider path only                                       |
|   extra destinations require a host-side grant                   |
+------------------------------------------------------------------+
       |
       | host-controlled copy OUT
       v
  quarantine + host-derived patch + finished source archive
       |
       +---- iterate: put the VM back to work
       +---- accept: apply patch to real working tree only
       +---- reject: destroy everything for that session
```

## Requirements

- Docker Sandboxes (`sbx`) **0.45.0 or newer**.
- Git.
- `rsync` and `tar` on the host.
- Optional custom golden toolbelt templates require Docker Desktop / Docker CLI for the one-time image build.

The 0.45.0 floor is deliberate. Docker Sandboxes 0.42.0 fixed macOS host-boundary vulnerabilities, and 0.45.0 contains additional credential/proxy security fixes. The wrapper refuses to create a session below the configured minimum.

The coding-agent executable is **not installed into your normal macOS PATH by this bundle**. It lives in Docker Sandboxes' image/template storage and runs inside the microVM. That still means agent image bytes exist in Docker Sandboxes' local cache. If you want those bytes and all Docker Sandboxes state gone afterward, use the `nuke` command described below.

## What is in this bundle

```text
locked-agent-sandbox-v2/
├── README.md
├── THREAT-MODEL.md
├── VALIDATION.md
├── bin/
│   └── agent-sbx
├── config/
│   └── defaults.env
└── templates/
    ├── codex.Dockerfile
    └── claude.Dockerfile
```

Run the controller in-place:

```bash
./bin/agent-sbx help
```

or, if you want a convenience command:

```bash
ln -s "$PWD/bin/agent-sbx" /usr/local/bin/agent-sbx
```

That symlink is only the host-side controller. It is not the coding agent.

---

# Normal lifecycle

The intended order is:

```text
harden -> doctor -> create -> prepare -> checkpoint -> auth -> run
                                                    -> iterate
                                                    -> export
                                                    -> accept | reject
```

The important detail is **checkpoint happens after the environment is runnable but before model credentials or agent execution**. That gives `reset` an exact clean, dependency-prepared restore point.

## 1. Harden Docker Sandboxes once

```bash
agent-sbx harden
agent-sbx doctor
```

`harden` configures the host-side boundary for this threat model:

```text
network baseline          deny-all
SSH agent forwarding      OFF
shared agent skills       OFF
clipboard image reads     OFF
Claude remote control     OFF (when supported)
sbx CLI telemetry         OFF for wrapper invocations
```

The strict create preflight also refuses to proceed if it cannot prove both of these are empty:

```text
host-global Docker Sandbox secrets
registered Docker Sandbox MCP servers
```

That is intentional. A global secret, a forwarded SSH agent, shared skills, or a host-run MCP server is a cross-boundary capability. This profile assumes none of them.

`doctor` is read-only and shows the current settings, policy, secrets, and MCP registrations.

## 2. Create a mountless session from the current repo state

Codex example:

```bash
agent-sbx create \
  --agent codex \
  --repo /absolute/path/to/triggr_api \
  --name triggr-api-agent
```

Claude example:

```bash
agent-sbx create \
  --agent claude \
  --repo /absolute/path/to/triggr_api \
  --name triggr-api-agent
```

This **does not start the coding agent** and **does not authenticate it**.

The wrapper creates a host-side sanitized snapshot of the current working-tree state, including tracked files and nonignored untracked files. It deliberately withholds the real `.git` directory and protected credential/config paths. It writes every exclusion to:

```text
~/.local/state/agent-sbx/sessions/<name>/excluded-from-snapshot.txt
```

The snapshot is copied into a sandbox created **without a host workspace path**. Inside the VM, the wrapper initializes a new synthetic Git repository with one baseline commit/tag:

```text
AGENT_SBX_BASELINE
```

The agent can branch, commit, reset, rebase, clean, or destroy that synthetic Git repository. None of it is your Git database.

### Do not replace this with direct or clone mode

For this threat model, do not use:

```bash
sbx run codex .
sbx run --clone codex .
```

The controller intentionally uses a mountless `sbx create` and then copies bytes into the VM. Your real working tree and `.git` are never the sandbox workspace.

## 3. Prepare the runnable development environment while the agent is OFF

For a normal Node project:

```bash
agent-sbx prepare triggr-api-agent
```

The wrapper tells you exactly which external hosts it will temporarily allow and requires you to type:

```text
ALLOW
```

It then chooses a deterministic lockfile install where possible:

```text
Yarn 2+   yarn install --immutable
Yarn 1    yarn install --frozen-lockfile
pnpm      pnpm install --frozen-lockfile
npm       npm ci
```

The temporary network allow rule is removed on success **or failure**.

For extra bootstrap destinations:

```bash
agent-sbx prepare triggr-api-agent \
  --allow 'registry.npmjs.org,registry.yarnpkg.com,github.com'
```

For a project-specific setup:

```bash
agent-sbx prepare triggr-api-agent \
  --allow 'registry.npmjs.org' \
  --cmd 'corepack enable && yarn install --immutable && yarn build'
```

You can also enter the VM manually before the checkpoint:

```bash
agent-sbx shell triggr-api-agent
```

This is the phase where you establish the **known-good runnable machine**: package dependencies, compilers, generated local artifacts, database images, whatever the project needs. Do not put production credentials into it.

## 4. Freeze that exact clean/runnable state

```bash
agent-sbx checkpoint triggr-api-agent
```

Checkpoint is only allowed before the agent has run and before model authentication.

It saves the current VM filesystem as a private local template such as:

```text
agent-sbx/triggr-api-agent:clean
```

From this point forward, `reset` means:

> destroy the contaminated session VM and recreate the exact prepared machine from this checkpoint.

So if the agent corrupts Node, deletes half the filesystem, wrecks Docker, or poisons its own config, you do not repair it. You delete it and recreate the clean prepared state.

## 5. Authenticate only this sandbox

```bash
agent-sbx auth triggr-api-agent
```

For Codex the service is `openai`; for Claude it is `anthropic`.

The secret is scoped to this sandbox rather than configured globally. Docker Sandboxes' credential proxy keeps the real provider credential on the host side and injects authentication into matching outbound requests instead of placing the raw secret into the VM filesystem.

Destroying/recreating the sandbox removes that sandbox-scoped authentication, so after a `reset` you authenticate again.

## 6. Explicitly turn the autonomous agent on

```bash
agent-sbx run triggr-api-agent \
  'Build X completely. Run tests, lint, typecheck, build, exercise the app, and keep working until it is finished.'
```

The controller requires the exact confirmation:

```text
START triggr-api-agent
```

Only then is the agent launched.

Once started, the agent is intentionally allowed to operate autonomously **inside the disposable VM**. The wrapper launches Codex/Claude in their no-interactive-approval mode because the microVM is the security boundary.

The agent may freely:

```text
edit/create/delete project files
run yarn/npm/pnpm commands
run lint/typecheck/tests/build/start
start local servers
use sudo inside the VM
use the VM's private Docker Engine
docker compose up / build / run
create databases and Redis instances
branch/commit/reset/rebase its synthetic Git repository
install tools when network policy permits it
keep iterating until the goal is complete
```

It does **not** receive your real `.git`, host workspace mount, host Docker daemon, SSH agent, GitHub token, AWS credentials, npm token, 1Password socket, shared agent skills, or MCP servers from this bundle.

## 7. Let it continue working on the same disposable machine

If the implementation is close but needs changes:

```bash
agent-sbx iterate triggr-api-agent \
  'Fix A and B, add the missing tests, rerun the whole validation suite, and do not stop until it passes.'
```

Again you must type:

```text
START triggr-api-agent
```

The existing VM state is preserved for iteration until you explicitly reset/reject/accept it.

---

# Network control

The global baseline is deny-by-default. The built-in agent kit contributes the provider connectivity required for its model traffic; everything else should remain unavailable unless you grant it.

Inspect the effective rules:

```bash
agent-sbx policy triggr-api-agent
```

See blocked/allowed attempts:

```bash
agent-sbx network-log triggr-api-agent
```

Temporarily or deliberately grant a destination:

```bash
agent-sbx network-allow triggr-api-agent registry.npmjs.org
```

Then remove it:

```bash
agent-sbx network-revoke triggr-api-agent registry.npmjs.org
```

The agent prompt explicitly tells the model not to evade network policy. More importantly, enforcement is outside the agent in the sandbox networking layer.

A cloud model provider is necessarily an external trust boundary. Project context sent to OpenAI or Anthropic can leave the machine as part of model operation. The claim here is **no arbitrary outbound internet/exfiltration path beyond provider traffic and destinations you explicitly approve**, not “no bytes ever leave the Mac.”

---

# Run and inspect the application

If the project starts a server inside the sandbox, publish only the port you want back to host loopback:

```bash
agent-sbx preview triggr-api-agent 3000
```

or choose a host port:

```bash
agent-sbx preview triggr-api-agent 3000 13000
```

Then use the printed `127.0.0.1` URL from your browser. Remove the publication with:

```bash
agent-sbx unpreview triggr-api-agent 3000
```

This is intentionally different from mounting your workspace. It exposes one service port, not your filesystem.

---

# Review what the agent produced

## Export without touching the real repo

```bash
agent-sbx export triggr-api-agent
```

The controller stops the VM, copies the finished workspace into a host quarantine directory, removes its synthetic `.git`, strips protected credential/config paths, overlays it onto the original sanitized baseline, stages that **quarantine** comparison tree, and derives the result on the host.

Output is under:

```text
~/.local/state/agent-sbx/results/triggr-api-agent/
```

Important files:

```text
result.patch                     binary-capable host-derived patch
finished-codebase.tar.gz         final source tree represented by the synthetic Git index
status.txt                       Git-style changed state
changed-files.txt                name/status list
changed-file-modes.txt           raw old/new Git modes
sensitive-changed-paths.txt      files worth extra manual review
diffstat.txt                     summary
quarantined-paths.txt            protected paths the agent produced but that were removed
excluded-from-input-snapshot.txt what never entered the VM
network-policy.txt               policy snapshot
network-log.txt                  network audit data when available
session-metadata.txt             baseline/session metadata
```

`finished-codebase.tar.gz` is intentionally built from the final synthetic Git tree rather than blindly archiving the runtime filesystem. Normal ignored runtime junk such as `node_modules`, caches, local databases, and build scratch space therefore does not become part of the code deliverable unless it is actually represented as source by Git rules.

Exporting does **not** modify your real repository.

## Accept

```bash
agent-sbx accept triggr-api-agent
```

Before it will touch the real working tree, the controller:

1. re-snapshots the host repo and verifies it still matches the exact baseline used to start the session;
2. refuses automatic application if your host working tree changed in the meantime;
3. rejects changed symlink/gitlink paths for manual review;
4. rejects `.gitmodules` changes for manual review;
5. runs `git apply --check`;
6. shows the diffstat and sensitive-path report;
7. requires the literal confirmation:

```text
ACCEPT triggr-api-agent
```

Only then does it run `git apply` against the real working tree.

It does **not** stage, commit, push, modify refs, change branches, alter remotes, edit Git config, or touch your real Git history.

After a successful accept, the disposable VM and its per-session clean checkpoint are deleted. The result/audit bundle is retained.

## Reject

```bash
agent-sbx reject triggr-api-agent
```

You must type:

```text
REJECT triggr-api-agent
```

The VM, session baseline, result bundle, and per-session checkpoint are destroyed.

---

# Recovery / destroy semantics

These commands intentionally mean different things:

```text
stop    pause only; VM filesystem persists
reset   destroy VM and recreate from clean checkpoint (or original snapshot if no checkpoint)
reject  destroy this session + its checkpoint + its local controller/result state
accept  apply validated patch, then destroy the session/checkpoint; retain audit output
nuke    wipe ALL Docker Sandboxes state/cache/config/policies/secrets/login + agent-sbx state
```

## Reset a poisoned agent environment

```bash
agent-sbx reset triggr-api-agent
```

Confirm:

```text
RESET triggr-api-agent
```

If you created the recommended checkpoint, the new VM is the exact dependency-prepared clean state. The old sandbox-scoped provider credential dies with the old VM, so authenticate again:

```bash
agent-sbx auth triggr-api-agent
```

Then explicitly start it again when you are ready.

## Scorched earth: remove cached agent/template bytes too

If simply deleting a session is not enough and you want Docker Sandboxes returned to a freshly-installed state:

```bash
agent-sbx nuke
```

It requires:

```text
NUKE ALL SANDBOX STATE
```

This invokes `sbx reset --force` and removes the wrapper's controller state. Docker documents `sbx reset` as deleting all sandbox state, image cache, registries, policies, stored secrets, Sandbox login, daemon state, cache, and config directories.

This affects **all Docker Sandboxes**, not merely the coding-agent session. It does not remove Docker Desktop and does not touch your real Git repositories.

After a nuke, run the hardening/bootstrap steps again before creating another session.

---

# Optional reusable dev toolbelt template

The built-in agent environments may be enough. If you want a known toolbelt available before project-specific `prepare`, this bundle includes optional templates for Codex and Claude with common build utilities, Python, PostgreSQL/Redis clients, Corepack, etc.

Build/load one:

```bash
agent-sbx build-template codex local/agent-sbx-codex:1
```

or:

```bash
agent-sbx build-template claude local/agent-sbx-claude:1
```

Then create with it:

```bash
agent-sbx create \
  --agent codex \
  --repo /absolute/path/to/repo \
  --name my-agent \
  --template local/agent-sbx-codex:1
```

The controller prints an optional command to remove the temporary host-Docker image after it has been loaded into Docker Sandboxes.

For project-specific reproducibility, the stronger pattern is still:

```text
base agent VM -> copy current source -> prepare exact dependencies -> checkpoint -> auth -> run
```

because the checkpoint captures the exact known-good runnable environment for that session without granting the agent access to your real machine.

---

# Things this design deliberately does not do

It does not rely on agent prompt obedience as the host security boundary.

It does not mount your actual repo read/write or read-only.

It does not give the agent your actual Git object database or remotes.

It does not preserve agent changes to its VM after `reset`/`reject`.

It does not make `stop` pretend to be a reset.

It does not automatically grant package registries, GitHub, AWS, or arbitrary HTTP access.

It does not automatically copy the finished workspace over your repo. Acceptance is host-side, checked, and explicit.

It does not claim the cloud model receives zero source code. If you need that property, use a local model rather than a cloud provider.

See `THREAT-MODEL.md` for the exact trusted-computing-base and failure assumptions.
