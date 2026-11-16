---
title: "Grow Box roadmap"
description: "The six stages of the Grow Box, its module, recipe and config model, and the decisions behind them."
status: draft
date: 2026-11-16
---

# Grow Box roadmap

## Intent

The Grow Box is a small place with one dedicated purpose: running a project's code, or a few services, in isolation. It serves the same goal as a larger private homelab, being protected, and it meets that goal with a lighter variation of the same stack.

It serves two uses, and each one is a branch of this roadmap:

- **Service deploy on a quasi-cloud.** A few services run behind a reverse proxy, with an orchestration panel and a pipeline that deploys ad-hoc instances, such as a fork of a service template. It works like a small cloud, on machines you own.
- **Isolated agentic development.** A dev machine for one stack runs a coding agent in isolation and is watched from outside. A rafa client inside it connects to a rafa hub, and the hub drives the work.

One interactive setup installs the parts you choose. It writes every choice into one config file, and that file rebuilds the same setup from scratch on another machine.

This roadmap fixes the stages, their order, and the model every stage shares. Each stage gets its own spec before it is built, and that spec settles the details this file leaves open.

## Goals, non-goals, anti-goals

Goals:

- One interactive setup installs the chosen parts, and asks only about what was chosen.
- The config file replays the whole setup without asking anything.
- Every stage can be skipped. When a stage above needs a skipped stage, setup installs a light default or a stub instead.
- The sandbox's protections hold without the rafa layer.

Non-goals:

- Images. The Grow Box installs onto machines; it ships no Docker or VM images for now.
- TLS. Certificates are the user's to set up. The docs link providers, what to research, and guides for a few known sites.
- Docs for every provider or setup. A how-to covers what the Grow Box supports and links out for the rest.

Anti-goals, which would make the work a failure even if it runs:

- A web UI reachable on the network without a sign-in.
- A secret in the config file.
- A stage that quietly breaks because a stage below it was skipped.
- A second prompt contract next to `@open-tomato/wizard`.

## Constraints

- **The repository is public.** The privacy check (`scripts/privacy-check.ts`, run by `.githooks/pre-commit` and CI) blocks private addresses, home paths, personal emails and secrets. Examples use reserved names: `example.com`, `.test`, `192.0.2.x`.
- **The config holds choices only.** Secrets are generated fresh on each install, on the target, and never leave it.
- **The operator runs every install.** Installs, pulls and `sudo` steps are commands the operator runs; nothing installs software behind their back.
- **Every new third-party package or service is vetted** (activity, security, maintainers, release age) before it is named in a recipe.
- **bun** is the runtime and package manager, as in the rest of open-tomato.
- **Targets run Ubuntu LTS**, on x64 or arm64; Multipass always gives Ubuntu. Another Debian-based system on a device is best effort. macOS is the operator's machine only: it runs the CLI and Multipass, and it is never a target.

### Work this roadmap depends on

- **`@open-tomato/wizard` and `@open-tomato/prompt`** are being designed in the open-tomato packages repository, on one shared contract. They do not exist yet. Recipe options are written once that contract lands; stage 1 does not wait for it.
- **The shared configs and gates** (`@open-tomato/eslint-config`, `@open-tomato/typescript-config`, `@open-tomato/gates`) are on the public npm registry, and the wizard and prompt packages publish there too. So a public clone, and GitHub's hosted CI runners, can install every dependency.
- **The Grow Box security profile** is being written by a separate security-baseline effort. Stage 2's SSH helper and stage 4's isolation take their rules from it (see "Security").

## Terms

| Term | Meaning here |
|---|---|
| Target | A machine the Grow Box installs onto, reached through one setup method: Multipass or SSH. |
| Module | A part of the Grow Box you choose to install, in its own folder: base, sandbox, orchestrator, and later rafa. |
| Recipe | One thing a module can install. It has options, the config it stores, an install routine, and the recipes it needs. |
| Seed | A sandbox recipe for one stack (for example TypeScript): the stack's dev tools on an empty machine. |
| Light default | A minimal install of a skipped recipe that a chosen recipe needs, at a low resource cost. |
| Stub | A stand-in that answers like the real recipe, so the recipe above it still works. |
| Answers file | The config file: every choice, grouped by module and recipe. It is the `@open-tomato/wizard` contract's answer-by-file mode. |
| Standard dependencies | Optional shared services (Postgres, Redis, open-notebook) shipped in the same bundle and wired to the rest of the stack out of the box. |

## The stages

The stages are built in order, and each builds on the ones it needs. Stage 4 does not need stage 3, so two chains start at stage 2:

```
1 directory structure
→ 2 setup methods
   → 3 infra services → 5 pipeline     (service deploy on a quasi-cloud)
   → 4 sandboxes      → 6 rafa layer   (isolated agentic dev)
```

| Stage | Contents | Needs | When skipped |
|---|---|---|---|
| 1 Directory structure | The monorepo: base, the sandbox module, the orchestrator module, the docs, and a place for the security concept and the Grow Box security profile. | nothing | Cannot be skipped. |
| 2 Setup methods | Targets through Multipass (the Grow Box makes the VM) or SSH (a server, VM or device that already runs), for the Grow Box and its sandboxes alike. | 1 | Cannot be skipped: every install needs a target. |
| 3 Infra services | Core: Portainer, Traefik, Pi-hole. On demand: Authentik (ships, off by default), Grafana, Prometheus, Loki, Alertmanager. Subdomain routing is an option. | 2 | Stage 5 gets a light default: Traefik alone. |
| 4 Sandboxes | Seeds for one stack. The first is TypeScript: node, TypeScript, bun, Claude Code, with SSH tunnels and tmux ready, run and watched from outside as isolated terminals. Agent tooling is a later layer. | 2 | Stage 6 cannot run: the rafa client runs only inside a sandbox. |
| 5 Pipeline | Specialised containers (visual testing first), an own control panel linking to the services, ad-hoc deployed instances such as a fork of a service template. Later: a local registry (Gitea) and security checks (OSV, Snyk). | 3 | Nothing above it. |
| 6 rafa layer | A rafa client in the sandbox connects to a rafa hub, which drives development inside the sandboxes. | 4 | Nothing above it. |

### First release

The first release (the MVP) is **stages 1, 2 and 4**: the wizard sets up a TypeScript sandbox on a Multipass VM or an SSH target. It tests the recipe model, the targets and the answers file on code that already works in `tools/sandbox/`, before any infra stack is written, and stage 4 needs no stage 3. Stage 3 with a first deploy behind Traefik comes next.

### Stage 2: setup methods

Two methods are supported, and they apply to every target:

- **Multipass.** The Grow Box launches or reuses an Ubuntu VM, as `tools/sandbox/launch-vm.sh` does today. A cloud-init file only prepares the VM; the install routines run after it boots.
- **SSH.** The Grow Box reaches a machine that already runs, as `tools/sandbox/launch-remote.sh` does today. That machine can be a server, a VM made by another tool, or a dedicated device.

A device the Grow Box cannot reach over SSH gets a how-to for setting up SSH access with the right permissions. The how-to and its helper follow one rule: a private key is made on the machine that uses it, and only the `.pub` file travels. The helper writes `authorized_keys` as a whole file, tests the new access, and rolls back on its own after a few minutes unless the test is confirmed. The key is referenced from a generated `ssh_config` entry, never loaded into an ssh-agent or passed through an environment variable. The permissions that account gets (sudo for the system phase, the docker group) are the security profile's to define.

Recipes for other provisioning tools can come later. Docker as a setup method comes much later, if it fits; until then the quick container check in `tools/sandbox/compose.quick.yaml` stays a local convenience and is not a supported method.

### Stage 3: infra services

Core infra is Portainer, Traefik and Pi-hole. The on-demand services are opt-in recipes.

**Authentik ships and is off by default.** It supports OAuth, most services can be wired to it, and the ad-hoc services from stage 5 support OAuth too. Examples that use Authentik as the quick, cheap sign-in come later.

**With Authentik off, web UIs listen only on the target's localhost**, and the operator reaches them through an SSH tunnel. This keeps the anti-goal: no web UI on the network without a sign-in. A tunnel needs no extra service.

The rule covers web UIs. A service that is not a web UI, such as Pi-hole's DNS on port 53, may listen on the network. A deployed instance listens on the network only when it has a sign-in of its own; otherwise it stays on localhost, like the admin UIs. So Traefik has two entry points: one on the network, and one on localhost. Sandboxes use Pi-hole only when stage 3 is installed; they never need it.

**Subdomain routing** through Traefik is an install option, for a stack that mimics several domains. **TLS** is the user's to set up; the docs link providers and what to research.

### Stage 4: sandboxes

Seeds use Multipass by default; Docker images may come much later. A seed is a provisioning layer for one stack, and it runs the same way over Multipass and over SSH: `tools/sandbox/provision.sh` already works like that. A finished seed can be kept with `multipass snapshot` and brought back with `multipass restore`, since Multipass has no layer cache of its own.

**Cloning repositories and running one command**, what the sandbox does today (`SANDBOX_REPOS`, `SANDBOX_RUN_CMD`), become options of the sandbox module: the repository rows, the branch and the command are stored in the answers file, and no token is. Deploy keys follow the same rule as SSH access: the key is made on the target, and only its `.pub` comes back to be registered as a read-only deploy key. Today the key is made on the operator's machine and copied over, so this changes in stage 4. `--ssh-key` and the token fallback stay opt-in and off by default, until the security profile rules on them.

**What "isolated" means** comes from the security profile: what the sandbox may reach on the network, which credentials an agent inside it may hold (Claude Code's own sign-in included), and what "watched from outside" guarantees.

## Modules, recipes and config

### Modules

| Module | Holds | Stages |
|---|---|---|
| base | the setup CLI, the target list, the standard dependencies | 1, 2 |
| sandbox | the seeds; today's `tools/sandbox/` moves here | 4 |
| orchestrator | the infra services and the pipeline, so infra without the pipeline is one choice inside it | 3, 5 |
| rafa (later) | the rafa client recipe, on top of the sandbox | 6 |

### A recipe

A recipe has five parts, and an optional sixth:

1. **Options**: its steps, choices and requirements, written in the `@open-tomato/wizard` contract. A step either works statically or calls a provider for dynamic data (for example, the list of running Multipass VMs).
2. **Config**: the answers it stores in the answers file. Choices only.
3. **Install routine**: a bash script that runs on the target. It is idempotent: run it again after a failure and it picks up where it stopped.
4. **Needs**: the recipes it requires. For example, the pipeline needs Traefik, and Authentik needs Postgres.
5. **Fallback**: for a critical recipe, its light default or its stub, used when a recipe that needs it is chosen and it was skipped.
6. **Removal** (optional): a routine that takes the recipe off its target. Today's `--reset` and `--purge` become removal routines of the sandbox recipes.

Each module defines its recipes in code, so it knows its own choices and what each one turns on or off. Choosing Authentik turns on the shared Postgres, the way a private homelab runs Authentik and Gitea on one shared Postgres.

### The setup flow

```
grow-box setup
→ base: targets, then standard dependencies (Postgres, Redis, open-notebook)
→ modules: sandbox and/or orchestrator
   → each chosen module asks its recipes' options
→ write the answers file
→ run each install routine on its target, needed recipes first
```

`grow-box setup --answers <file>` replays an answers file with no questions. The command name is a placeholder.

**A replay converges and never removes**, the way the private homelab's apply only reconciles. A recipe that is on gets installed or brought up to date. A recipe set to `false` is left as it is, and `grow-box doctor` reports it as drift. Removing is its own command, `grow-box <module> remove <recipe>`, which runs the recipe's removal routine. When a recipe's wiring depends on another, changing that other one re-runs it: turning Authentik on re-runs Traefik and the recipes behind it.

**Targets per module.** The orchestrator uses one target. The sandbox module takes a list of sandboxes, each with its own target and seed.

**Standard dependencies** have one shared instance each. It goes on the orchestrator's target by default, or on the first sandbox's target when there is no orchestrator, and the answers file can name another. Postgres serves Authentik, Gitea later, and deployed instances. Redis serves deployed instances that need a cache. open-notebook is a notebook service that holds a project's docs, to ask questions over them.

### The answers file

The `@open-tomato/wizard` contract decides the file's format. This example only shows what it holds:

```yaml
# Grow Box answers file: choices only, never secrets.
targets:
  - name: box
    method: ssh            # multipass | ssh
    host: box.example.test
  - name: dev-1
    method: multipass
base:
  dependencies:
    postgres: true
    redis: false
    open-notebook: false
modules:
  orchestrator:
    target: box
    traefik: { subdomains: false }
    portainer: true
    pihole: true
    authentik: false
    grafana: false
    pipeline: true
  sandbox:
    - name: dev-1
      target: dev-1
      seed: typescript
      claude-code: true
      repos:
        - { owner: example, repo: service, branch: main }
      run: bun run test
```

### Secrets

Secrets never enter the answers file. Each recipe that needs one declares it in its `.env.example` with a marker, and the install routine fills it on the target:

| Marker | Meaning |
|---|---|
| `KEY=GENERATE` | A machine secret: generated on the target, once. |
| `KEY=GENERATE:hex32` | The same, in a given format. |
| `KEY=change-me` | An external secret (an API key, OAuth client): the operator fills it. |

A filled value is never overwritten, because regenerating a database password after the database started would lock the service out.

## Directory structure (stage 1)

The layout follows the open-tomato conventions: a bun workspace run by turbo, the shared `@open-tomato/eslint-config` and `@open-tomato/typescript-config`, an `AGENTS.md` per area, and the hooks in `.githooks/`. Paths are relative to the repository root:

```
package.json                bun workspace root (base, modules/*)
turbo.json
base/                       the setup CLI, targets, the recipe registry
  src/cli/                  routing, dispatch, the ending of a run
  src/commands/<subject>/   one file per action: setup, doctor, describe, ...
  src/ports/                the Transport port
  src/adapters/transport/   multipass, ssh, stub
  recipes/postgres/         the standard dependencies, one folder each
  recipes/redis/
  recipes/open-notebook/
modules/
  sandbox/                  today's tools/sandbox moves here
    package.json            its manifest lists its recipes
    recipes/typescript/     recipe.ts, install.sh, .env.example
  orchestrator/
    recipes/traefik/        one folder per service: recipe.ts, install.sh,
    recipes/portainer/        compose.yaml, .env.example
    recipes/pihole/
    recipes/authentik/      off by default
    recipes/grafana/ ...    prometheus, loki, alertmanager
    recipes/pipeline/
docs/
  roadmap.md                this file
  security/                 the security concept and the Grow Box profile
  how-to/                   SSH access, TLS pointers
scripts/                    the privacy check
tests/
```

Each service is its own recipe, so turning one on or off never touches another's folder.

### Patterns taken from the rafa CLI

The recipe routines follow the way the rafa CLI is built:

| rafa pattern | In the Grow Box |
|---|---|
| A command is a frozen, declarative object: name, summary, description, args and flags as data, examples, outputs, `run`. | A recipe is a frozen, declarative object in `recipe.ts`: name, summary, options, needs, config section, install routine, fallback. |
| An add-on module declares a manifest in its `package.json`; a broken one is skipped with a named warning, never silently. | Each module's `package.json` lists its recipes; a recipe that fails to load is reported by name. |
| Routing is subject plus action (`rafa loop resume`), a pure function that refuses with named codes. | `grow-box <module> <action>`, refusing with named codes such as `unknown_module` or `unknown_recipe`. |
| `describe` builds one JSON document from the live registry, so it lists exactly what can run. | `grow-box describe` emits the modules, recipes, options and needs from the same declarations the installer uses. The options keep the wizard contract's own export format, so there is no second roster. |
| `doctor` reads needs into data first, then renders rows (`ok`, `warn`, `note`, with a `fix`); seams such as the environment are injected; it never throws. Probes chain: each runs only if the one before passed. | `grow-box doctor` checks each chosen recipe's needs on its target and prints a row with a fix. A chained probe: Multipass found, then the VM running, then SSH reachable. |
| A config section per package (settings, defaults, cross-key checks), registered in one composition root; `config set` edits the YAML text by dotted key and keeps comments. | One config section per recipe, registered once in base; editing the answers file keeps its comments. |
| Ports and adapters: an interface with kinds registered explicitly, never by import side effect. | A `Transport` port with the kinds `multipass`, `ssh` and `stub` (the stub for tests). |
| Prompts go through an injectable terminal and refuse when there is no TTY, so a run never hangs. | The same, through `@open-tomato/prompt` and `@open-tomato/wizard`. |
| A run emits `start`, `step`, `log` events and ends with one `result` event, NDJSON in json mode, with one hint on failure and fixed exit codes. | The same event stream, so a TUI or rafa can watch an install live. |
| `scripts/device/check.sh`: `set -uo pipefail`, `--flag=value` arguments, fixed exit codes, bash 3.2 and BSD tools. | Every bash script keeps `set -uo pipefail`, `--flag=value` and fixed exit codes. The scripts that run on the operator's machine also keep bash 3.2 and BSD tools, so they run on macOS; install routines target Ubuntu. |

rafa has no step runner that resumes a routine part-way, so that runner is new Grow Box code. It runs each install routine on its target through the Transport port and emits a `step` event per phase. The routines themselves stay idempotent, as `tools/sandbox/provision.sh` is today.

## Learnings carried over from the private homelab

- **One stack, one folder**, with a `compose.yaml`. HTTP services are reached through Traefik labels, never host ports. Databases join a private network for their stack only.
- **Pin each private Docker network's subnet.** When Docker's default address pool is full, it falls back to a range that can overlap the LAN, and the target then loses its route to LAN hosts.
- **Data lives outside git**, under one data root on the target, one folder per service. Containers run as a dedicated service user, never as root or the operator.
- **Secrets are declared by marker** (`GENERATE`, `change-me`), generated once, and rotated through a hook per key.
- **Breaking changes ship as numbered migrations**: idempotent, run once each, in order, with the applied list recorded on the target. Everything else converges by re-running the install.
- **Images are pinned by digest**, so a re-run installs the same bytes.
- **Admin and monitoring UIs are never public.** A sign-in middleware that denies by default needs its access rule in the same change, or every client gets a 403.

The homelab's stacks and scripts are reference material as well. A recipe may port one, file by file, rewritten for the recipe layout and passed through the privacy check.

## Security

The security concept (the goal of being protected, and the protections that serve it) and the Grow Box security profile live in `docs/security/`. A separate security-baseline effort writes them and places each protection on one of the stages above. The sandbox's protections hold without stage 6.

Two stages read rules from the profile. Stage 2's SSH helper takes the account's permissions from it (sudo for the system phase, the docker group). Stage 4 takes what "isolated" means. Each stage's spec waits for the profile's rules on it, and its done-line includes the profile's checks for that stage.

## Approaches

Three ways to build the module and recipe model were weighed:

| | A. TypeScript recipes, bash installs (picked) | B. Recipes as data files | C. All TypeScript |
|---|---|---|---|
| Recipe options | a `recipe.ts` per recipe, in the wizard contract | a YAML file per recipe | a `recipe.ts` per recipe |
| Install routine | a bash script run on the target | a bash script | TypeScript, run by bun on the target |
| Gains | conditions and ramifications are code; today's bash installs move over unchanged | the TUI and rafa read the files directly | one language |
| Costs | the contract must export JSON for the TUI and rafa | conditions in YAML turn into a small private language | bun must reach every target first, and the working bash provisioning is rewritten |

A was picked because each module defines its steps in code and knows their ramifications, and because a fresh Ubuntu target runs bash out of the box.

## Decisions

| Question | Decision |
|---|---|
| Do the setup methods cover the Grow Box, its sandboxes, or both? | Both. Multipass and SSH; no images. A device without SSH gets the SSH-access how-to. |
| Does stage 4 need stage 3? | No. |
| Authentik permissive, or authenticated and unauthenticated bundles? | Authentik ships, off by default. Off means web UIs on localhost, reached through an SSH tunnel. |
| Docker images or Multipass VMs for the seeds? | Multipass by default; Docker images much later, if they fit. |
| Localhost subdomains and TLS? | Subdomain routing is an option. TLS is the user's; the docs link out. |
| How do the Rust TUI and rafa read the recipes? | The `@open-tomato/wizard` contract answers it; the recipes are written against that contract. |
| Prompt library | `@open-tomato/wizard`, an adapter over `@inquirer/prompts`. |
| Which way to build the model? | A: TypeScript recipes, bash install routines, following the open-tomato layout and the rafa CLI's patterns. |
| What are the standard dependencies? | Optional shared services in the same bundle, wired to the rest of the stack out of the box. |
| What makes the first release? | Stages 1, 2 and 4: a TypeScript sandbox set up by the wizard. Stage 3 with a first deploy comes next. |

## Later

- Docker images, and Docker as a setup method.
- Recipes for other provisioning tools.
- Agent tooling in the sandbox, beyond Claude Code itself.
- A local registry (Gitea) and security checks (OSV, Snyk) in the pipeline.
- A review of the roadmap from several viewpoints, after the first release.

## Left to the builder

- The CLI's final name and the package names of base and the modules.
- The step runner that runs install routines over the Transport port, and how it records which phases finished.
- Where the answers file is written by default, and its file name.
- How Multipass snapshots of finished seeds are named and listed.
- How Claude Code is installed in the TypeScript seed, after vetting the install method.
- The order in which today's `tools/sandbox/` scripts and `tests/` move into `modules/sandbox/`, keeping `bash tests/run.sh` green at each step.

## Definition of done

The roadmap is done stage by stage:

| Stage | Done when |
|---|---|
| 1 | The workspace builds, lints and passes its tests through turbo; today's sandbox tests pass from their new place; the privacy check runs on every commit. |
| 2 | `grow-box setup` adds a Multipass target and an SSH target; `grow-box doctor` reports each one's reachability with a fix; the SSH-access how-to exists. |
| 3 | Traefik, Portainer and Pi-hole install on a target from an answers file; Authentik installs when chosen and pulls in Postgres; with Authentik off, no web UI listens beyond the target's localhost. |
| 4 | The TypeScript seed installs on a Multipass VM and on an SSH target from the same answers file; a finished seed can be snapshotted and restored; deploy keys are made on the target; the security profile's sandbox checks pass. |
| 5 | The pipeline deploys an ad-hoc instance behind Traefik; with stage 3 skipped, it installs Traefik alone as its light default. |
| 6 | A rafa client in a sandbox connects to a rafa hub; choosing rafa without a sandbox is refused with a named reason. |

At every stage, replaying the answers file on a fresh target rebuilds the same setup, with fresh secrets.

## For the documentation writer

Material from the design conversation, for the docs. It is not work to plan.

**Use cases, lightest first.**

- *One developer, one laptop.* Only the sandbox module: a Multipass VM with the TypeScript seed, where a coding agent works in isolation while the developer watches its tmux session from outside.
- *One developer, a spare machine.* The orchestrator on a small server or device over SSH: Traefik, Portainer and Pi-hole, then the pipeline deploying a fork of a service template. A quasi-cloud on hardware they own.
- *A small team.* One person runs the setup and shares the answers file; each teammate replays it and gets the same setup, with their own fresh secrets.
- *Agentic development at scale.* Several sandboxes, each with a rafa client, driven by one rafa hub.

**Edge cases worth an example.**

- A device with no SSH access yet: setup stops at the target step and links the SSH-access how-to.
- Authentik off: Grafana listens on the target's localhost only, and the operator opens it through `ssh -L`.
- The pipeline chosen with stage 3 skipped: setup installs Traefik alone and says so.
- rafa chosen with no sandbox: setup refuses, because the rafa client runs only inside a sandbox.
- Replaying an answers file next to old data: the secrets are new, so a restored database will not accept them. Restore the old `.env` with the data, or start the data fresh.

**Config examples, from empty to full.**

1. A sandbox only: one Multipass target and one entry under `modules.sandbox` with `seed: typescript`.
2. Add the orchestrator on an SSH target: Traefik, Portainer, Pi-hole.
3. Turn Authentik on: Postgres turns on with it.
4. Add the pipeline and the monitoring services: the full example in "The answers file", with every flag on.

**Words and images the user used.**

- "The concept": the goal of being protected, which the homelab and the Grow Box both serve with a variation of one stack. It names the goal, not the stack.
- "A quasi-cloud simulated environment" for the service-deploy branch.
- "Seeds per project type" for the sandbox recipes.
- A skipped stage is "stubbed so the stage above still works, or installed gently at low resource cost".

**Rejected alternatives.**

- Recipes as YAML data files: conditions would turn into a small private language.
- All TypeScript, run by bun on the target: bun would have to reach every target first, and the working bash provisioning would be rewritten.
- Docker images for the seeds now: Multipass first; images much later, if they fit.
- Authentik on from the start, or separate authenticated and unauthenticated bundles: Authentik ships off, and off means localhost plus an SSH tunnel.
- A prompt contract defined in this repository: `@open-tomato/wizard` owns it.
- Keeping TLS guides for every provider: too much documentation for a maybe; the docs link out.
