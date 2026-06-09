# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile (SMALL form, PREFERRED) — builds ON TOP of the org C/C++ base
# image (ghcr.io/mayhemheroes/base). The base already provides debian + clang/llvm +
# libFuzzer/afl++ + the identities + the build-contract ENV, so this only adds the
# per-commit build (built on top of the prebuilt base, rather than building the toolchain in-image).
#
# Build (from the repo root):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] \
#       -t mytag .

# The org base, pinned to a fixed YEAR-MONTH base (shared by all integrations in that
# period). Bump deliberately; pin by digest in production: ...base@sha256:<digest>.
FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); do NOT bake it as an ENV — an
# empty value breaks clang ("must be a non-negative decimal integer") both here and for
# any in-image rebuild. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: default is the base's SANITIZER_FLAGS (ASan+UBSan, halting). To change it
# for a build (e.g. ASan-only, or add MSan), pass --build-arg SANITIZER_FLAGS="-fsanitize=address ...".
ARG SANITIZER_FLAGS
# Build parallelism (optional). build.sh falls back to nproc when unset: --build-arg MAYHEM_JOBS=8
ARG MAYHEM_JOBS=

# iproute2's ./configure + make need these to build the full feature set (libmnl/libbpf/libelf for
# tc/devlink/etc., bison+flex for the tc parsers, libdb for arpd, pkg-config to find them). Install
# as root, re-pinning the apt snapshot to SOURCE_DATE_EPOCH when set (reproducible; script ships in base).
USER root
RUN [ -n "$SOURCE_DATE_EPOCH" ] && repro-sources-list.sh || true ; \
    apt-get update && apt-get install -yq --no-install-recommends \
        libdb-dev libmnl-dev libbpf-dev libelf-dev bison flex pkg-config \
 && rm -rf /var/lib/apt/lists/*
USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git
# history) is copied to /mayhem as `mayhem`; build.sh builds in place.
USER mayhem
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run the project's functional tests at build time IF the repo ships them (mayhem/test.sh is
# optional — omit it only when the repo has no tests meaningful for RL). A failing suite fails the
# image build, so the commit image is guaranteed to build AND pass its own tests.
# iproute2's mayhem/test.sh runs the one privilege-free subset of its own testsuite —
# testsuite/tests/ss/ssfilter.t — which exercises the NORMAL-flags `ss` binary against a shipped
# socket capture (via $TCPDIAG_FILE), needing no root/netns/kernel modules. The other testsuite
# tests (ip/tc/bridge) need CAP_NET_ADMIN + `unshare -n`, so they are intentionally excluded.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh — repo ships no functional tests"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
