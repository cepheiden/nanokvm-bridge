#!/bin/bash
# Builds the bridge + USB Ethernet modules for YOUR NanoKVM's running kernel.
#
#   ./build/build.sh root@<nanokvm-ip> [out-dir]
#
# Reads /proc/config.gz and `uname -r` from the device over SSH, builds in Docker
# (any Docker works; on macOS with Colima the repo must live under $HOME so it can be mounted).
set -euo pipefail

TARGET=${1:?usage: $0 root@<nanokvm-ip> [out-dir]}
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(mkdir -p "${2:-$HERE/../out}" && cd "${2:-$HERE/../out}" && pwd)
IN=$(mktemp -d "$HERE/../.in.XXXXXX")
trap 'rm -rf "$IN"' EXIT

echo ">> reading kernel config from $TARGET"
ssh "$TARGET" 'zcat /proc/config.gz' > "$IN/kernel.config"
ssh "$TARGET" 'uname -r' > "$IN/kernel.release"
ssh "$TARGET" 'cat /proc/version' > "$OUT/proc-version.txt"
echo "   $(cat "$IN/kernel.release"), $(wc -l < "$IN/kernel.config") config lines"

docker build -q -t nanokvm-kbuild "$HERE" >/dev/null
# named volume keeps the kernel source between runs
docker run --rm -v nanokvm-kbuild-src:/work -v "$IN":/in:ro -v "$OUT":/out nanokvm-kbuild
cp "$IN/kernel.config" "$OUT/kernel.config"
echo ">> modules in $OUT"
