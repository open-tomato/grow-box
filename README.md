# Grow Box

Grow Box prepares a sandbox, a machine where a project's code can be
cloned, installed and checked in isolation, and keeps it ready for the
next run. A sandbox can be a local virtual machine, a remote host you
reach over SSH, or a throwaway container.

This is an early version. Today it covers the bottom of the stack:
making or reaching the machine, provisioning its system tools, cloning
your repositories and running one command. Layered recipes and size
presets come next.

## What it does today

| Medium | Entry point | What happens |
|---|---|---|
| Local VM (multipass) | `bash tools/sandbox/launch-vm.sh` | launches or reuses an Ubuntu 24.04 VM, provisions it, clones the repos, runs the command |
| Remote host over SSH | `bash tools/sandbox/launch-remote.sh --name <ssh-alias> --ip <ip>` | the same on a machine you already have; `--reset`, `--regenerate` and `--purge --confirm purge` clean it up |
| Container | `docker compose -f tools/sandbox/compose.quick.yaml up -d`, then `exec sandbox bash` | a quick check without a VM: an Ubuntu image with the toolchain, this repo mounted, and a throwaway Docker daemon beside it |
| Any box by hand | `sudo bash tools/sandbox/provision.sh system`, then `bash tools/sandbox/provision.sh user` | installs the system tools, then bun for the user |

Every launcher is idempotent: run it again after a failure and it picks
up where it stopped. Run either launcher with no arguments for its full
usage.

## Inputs

| Variable | Meaning |
|---|---|
| `SANDBOX_REPOS` | the repositories to clone, as rows `owner|repo|optname`, separated by newlines or commas; each is cloned to `~/<optname>` and linked at `/opt/<optname>` |
| `SANDBOX_REPOS_FILE` | a file of such rows, instead of `SANDBOX_REPOS` |
| `SANDBOX_RUN_CMD` | the command to run once the repos are in place; unset, the run step is skipped |
| `SANDBOX_RUN_DIR` | where that command runs; defaults to `/opt/<optname>` of the first row |
| `GH_TOKEN` | a GitHub token, used on your machine to register a read-only deploy key per repository; `gh auth token` is used when it is unset |
| `SANDBOX_ALLOW_TOKEN_FALLBACK` | set to `1` to clone with a token when deploy keys cannot be registered; off by default |
| `SANDBOX_GH_TOKEN_FILE` | a file holding the token for that fallback, instead of `GH_TOKEN` |
| `BUN_VERSION` | the bun version to install; defaults to `tools/.bun-version` |

With no repositories set, nothing is cloned and no credentials are
staged.

## Trust and safety

Use dedicated, throwaway machines. `launch-remote.sh` changes the host
you point it at: it installs packages, adds your user to the `docker`
group, clones into your home directory and links under `/opt`.
`--reset` deletes those clones, the deploy keys in `~/.ssh` and the
`.npmrc` Grow Box wrote. `--purge` also removes Docker. Never point it
at a machine you rely on.

`SANDBOX_RUN_CMD` is any shell command, and it runs on the box with the
repositories' deploy keys and any staged `.npmrc` in place. The command
is also printed in the log as it is, so never put a secret in it.

`--ssh-key` copies that private key to the box. Use a key made for the
sandbox, one you can revoke, and never your main key.

When deploy keys cannot be registered, the run stops. Setting
`SANDBOX_ALLOW_TOKEN_FALLBACK=1` lets it clone with a token instead.
That token, from `GH_TOKEN` or `SANDBOX_GH_TOKEN_FILE`, is copied to the
box and stays there until `--reset` or `--destroy`. The token from
`gh auth token` is never copied.

## Tests

```bash
bash tests/run.sh
```

The tests stub every remote command, so they run anywhere bash runs.

## Privacy check

Every commit is checked for secrets, private network addresses, home
paths and personal email addresses. Turn the hook on once per clone:

```bash
git config core.hooksPath .githooks
```

CI runs the same check, plus gitleaks over the history.

## License

Apache-2.0. See `LICENSE` and `NOTICE`.
