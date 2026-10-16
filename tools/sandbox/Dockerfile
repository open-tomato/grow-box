# Tier 1 — fast loop: a project's lint and tests, without a VM.
#
# No Docker daemon inside this image; it exercises the bun/bash/lint surface
# (checks that need a daemon or a full host belong to the Tier 2 VM). It never sees
# the host docker socket — isolation by construction.
#
# Build (from repo root):  docker build -f tools/sandbox/Dockerfile -t grow-box-sandbox .
# Shell:                   docker run --rm -it -v "$PWD:/work" grow-box-sandbox
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq curl ca-certificates git && \
    rm -rf /var/lib/apt/lists/*

# Provision the toolchain via the shared, OS-agnostic script, in privilege
# phases. The image builds AS root, so `system` (the privileged stage) runs
# directly and `user` installs bun into /root/.bun (correct here — the container
# user IS root). SKIP_DOCKER=1 because this tier has no daemon. Copy only the
# provisioner first so the (slow) toolchain layer caches independently of repo
# source changes.
WORKDIR /work
COPY tools/.bun-version tools/.bun-version
COPY tools/sandbox/provision.sh tools/sandbox/provision.sh
RUN SKIP_DOCKER=1 bash tools/sandbox/provision.sh system && \
    bash tools/sandbox/provision.sh user
ENV PATH="/root/.bun/bin:${PATH}"

# Repo source is bind-mounted at run time (the -v above), so edits on the host
# are visible without a rebuild. Nothing else is baked in.
CMD ["bash"]
