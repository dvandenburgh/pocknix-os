#!/usr/bin/env bash
# ./build.sh [options] — the whole image build in one command: host check, kernel,
# packages, rootfs and the SD image, with a progress bar and time-left estimate. The same as
# `make image`, with flags: ./build.sh --ssh, ./build.sh --no-sd-image, ./build.sh --help.
exec "$(dirname "$0")/scripts/build-all.sh" "$@"
