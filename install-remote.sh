#!/bin/bash
# One-liner install: curl -fsSL https://raw.githubusercontent.com/kubestellar/pluk/main/install-remote.sh | bash
set -euo pipefail

PREFIX="${1:-/usr/local}"
REPO="https://github.com/kubestellar/pluk.git"
TMPDIR="$(mktemp -d)"

trap "rm -rf $TMPDIR" EXIT

echo "Installing pluk to ${PREFIX}..."
git clone --depth 1 "$REPO" "$TMPDIR/pluk" 2>/dev/null
bash "$TMPDIR/pluk/install.sh" "$PREFIX"
