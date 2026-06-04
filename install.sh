#!/bin/bash
# install.sh — install pub-sub-tmux to the system
set -euo pipefail

PREFIX="${1:-/usr/local}"
BINDIR="${PREFIX}/bin"
LIBDIR="${PREFIX}/lib/pub-sub-tmux"
CONFDIR="${PREFIX}/etc/pub-sub-tmux"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing pub-sub-tmux to ${PREFIX}..."

mkdir -p "$BINDIR" "$LIBDIR" "$CONFDIR/patterns.d"

for bin in pst-publish pst-subscribe pst-send; do
  install -m 755 "${SCRIPT_DIR}/bin/${bin}" "${BINDIR}/${bin}"
done

for lib in pst-common.sh pst-json.sh pst-patterns.sh; do
  install -m 644 "${SCRIPT_DIR}/lib/${lib}" "${LIBDIR}/${lib}"
done

for pat in "${SCRIPT_DIR}"/config/patterns.d/*.patterns; do
  [ -f "$pat" ] || continue
  dest="${CONFDIR}/patterns.d/$(basename "$pat")"
  if [ ! -f "$dest" ]; then
    install -m 644 "$pat" "$dest"
  fi
done

echo "pub-sub-tmux installed to ${BINDIR}"
echo "  binaries: ${BINDIR}/pst-{publish,subscribe,send}"
echo "  library:  ${LIBDIR}/"
echo "  patterns: ${CONFDIR}/patterns.d/"
