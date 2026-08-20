# Build environment for the Linux dedicated server release.
#
# Debian 11 on purpose, not something current. glibc symbol versioning only
# works one way: a binary built against 2.31 runs on 2.35, never the reverse.
# Debian 11 gives glibc 2.31, so the release runs on Ubuntu 20.04 and anything
# newer, which covers every distro likely to end up on a VPS.
#
# Same reasoning as the 10.6 deployment target on the Intel Mac slice: build
# against the floor, run everywhere above it.
FROM debian:11

RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      file \
      zlib1g-dev \
      pkg-config \
      procps \
      iproute2 \
 && rm -rf /var/lib/apt/lists/*
