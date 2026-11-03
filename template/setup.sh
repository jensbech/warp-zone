#!/usr/bin/env bash
set -euo pipefail

# Per-profile build hook: runs as root at the end of every image build, after
# all selected tools are installed. Add anything the tool catalog can't
# express — exact package versions, config files, extra downloads — like the
# RUN lines of a Dockerfile. Rebuild with `just rebuild <profile>` to apply.
#
# Example:
#   apt-get update
#   apt-get install -y --no-install-recommends postgresql-16
#   rm -rf /var/lib/apt/lists/*
