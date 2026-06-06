#!/bin/bash
# install.sh — install pluk to the system
#
# Usage:
#   ./install.sh [PREFIX]           # from a cloned repo
#   curl -sL <url>/install.sh | bash  # auto-clones to /tmp
set -euo pipefail

PREFIX="${1:-/usr/local}"
if [ -z "$PREFIX" ]; then
  echo "error: PREFIX is empty — refusing to install" >&2
  exit 1
fi
BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/pluk"
CONFDIR="${PREFIX}/etc/pluk"

# Resolve source directory. When piped via curl|bash, $0 is "bash" and
# there's no local repo — clone to a temp dir automatically.
_resolve_source() {
  local src="$0"
  while [ -L "$src" ]; do
    local dir
    dir="$(cd "$(dirname "$src")" && pwd)"
    src="$(readlink "$src")"
    [[ "$src" != /* ]] && src="$dir/$src"
  done
  local resolved
  resolved="$(cd "$(dirname "$src")" 2>/dev/null && pwd)" || resolved=""

  # Check if we're in the repo (bin/ dir exists alongside us)
  if [ -n "$resolved" ] && [ -d "${resolved}/bin" ] && [ -f "${resolved}/bin/pluk-publish" ]; then
    echo "$resolved"
    return
  fi

  # Not in repo — likely piped via curl|bash. Clone to temp.
  echo "  (piped install detected — cloning repo to temp dir)" >&2
  local tmpdir
  tmpdir="$(mktemp -d)"
  git clone --depth 1 https://github.com/kubestellar/pluk.git "$tmpdir" >/dev/null 2>&1
  echo "$tmpdir"
}

SCRIPT_DIR="$(_resolve_source)"

echo "Installing pluk to ${PREFIX}..."

mkdir -p "$BINDIR" "$LIBDIR" "$CONFDIR/patterns.d"

for bin in pluk-publish pluk-subscribe pluk-send; do
  if [ ! -f "${SCRIPT_DIR}/bin/${bin}" ]; then
    echo "error: ${SCRIPT_DIR}/bin/${bin} not found" >&2
    exit 1
  fi
  install -m 755 "${SCRIPT_DIR}/bin/${bin}" "${BINDIR}/${bin}"
done

for lib in pluk-common.sh pluk-json.sh pluk-patterns.sh; do
  if [ ! -f "${SCRIPT_DIR}/lib/${lib}" ]; then
    echo "warning: ${SCRIPT_DIR}/lib/${lib} not found — skipping" >&2
    continue
  fi
  install -m 644 "${SCRIPT_DIR}/lib/${lib}" "${LIBDIR}/${lib}"
done

for pat in "${SCRIPT_DIR}"/config/patterns.d/*.patterns; do
  [ -f "$pat" ] || continue
  dest="${CONFDIR}/patterns.d/$(basename "$pat")"
  if [ ! -f "$dest" ]; then
    install -m 644 "$pat" "$dest"
  elif ! cmp -s "$pat" "$dest"; then
    echo "  note: $(basename "$pat") differs from installed version (not overwritten)"
  fi
done

echo "pluk installed to ${BINDIR}"
echo "  binaries: ${BINDIR}/pluk-{publish,subscribe,send}"
echo "  library:  ${LIBDIR}/"
echo "  patterns: ${CONFDIR}/patterns.d/"
