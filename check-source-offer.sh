#!/usr/bin/env bash
# Proof that a build is publishable: the link trace is not empty, the source
# archive holds a source tarball for every library the trace lists, and the
# binary tarball holds that library's licence text.
#
#   check-source-offer.sh <binary tarball> <source archive>
#
# LINK-TRACE.txt (in the binary tarball, written by build.sh from the linker map
# of ffmpeg and ffprobe) is tab-separated, one linked library per line:
#   built    <name>     <tarball name in the source archive>   <licence dir under LICENSES/>
#   debian   <srcpkg>   <version, epoch stripped>              <licence dir under LICENSES/>
#   runtime  <name>     <binary package>                       <licence dir under LICENSES/>
# `built`: a library compiled from a pinned commit (the source tarball is in the
# archive's top directory). `debian`: a Debian static archive (the archive holds
# debian/<srcpkg>_<version>.dsc and every file that .dsc lists). `runtime`: the
# compiler runtime (licence text only; it carries the GPL runtime exception).
# Every line needs at least one licence file under LICENSES/<dir>/.
set -euo pipefail
BIN="${1:?binary tarball}"; SRC="${2:?source archive}"
fail() { echo "check-source-offer: $*" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
tar -tf "$BIN" > "$TMP/bin.list"
tar -tf "$SRC" > "$TMP/src.list"

trace_member="$(grep -E '^[^/]+/LINK-TRACE\.txt$' "$TMP/bin.list" || true)"
[ -n "$trace_member" ] || fail "$(basename "$BIN") has no LINK-TRACE.txt"
BTOP="${trace_member%%/*}"
tar -xOf "$BIN" "$trace_member" > "$TMP/trace"
[ -s "$TMP/trace" ] || fail "the link trace is empty: nothing proves what was linked"

STOP="$(head -1 "$TMP/src.list" | cut -d/ -f1)"
[ -n "$STOP" ] || fail "the source archive is empty"

n=0; ndeb=0
while IFS=$'\t' read -r kind name ref lic; do
  [ -n "$kind" ] || continue
  n=$((n + 1))
  [ -n "$name" ] && [ -n "$ref" ] && [ -n "$lic" ] || fail "malformed trace line: $kind $name $ref $lic"
  case "$kind" in
    built)
      grep -qxF "$STOP/$ref" "$TMP/src.list" || fail "$name: the source archive has no $ref"
      ;;
    debian)
      ndeb=$((ndeb + 1))
      dsc="debian/${name}_${ref}.dsc"
      grep -qxF "$STOP/$dsc" "$TMP/src.list" || fail "$name: the source archive has no $dsc"
      tar -xOf "$SRC" "$STOP/$dsc" > "$TMP/dsc"
      files="$(awk '/^Checksums-Sha256:/ {f=1; next} f && /^ [0-9a-f]+ [0-9]+ / {print $3; next} f {f=0}' "$TMP/dsc")"
      [ -n "$files" ] || fail "$name: $dsc lists no files"
      while read -r f; do
        grep -qxF "$STOP/debian/$f" "$TMP/src.list" || fail "$name: the source archive has no debian/$f (listed by $dsc)"
      done <<<"$files"
      ;;
    runtime) ;;
    *) fail "unknown trace kind '$kind'" ;;
  esac
  # at least one licence file (not a directory entry) under LICENSES/<dir>/
  grep -E "^$BTOP/LICENSES/$lic/.*[^/]$" "$TMP/bin.list" >/dev/null || fail "$name: no licence text under LICENSES/$lic/ in the binary tarball"
done < "$TMP/trace"

[ "$n" -gt 0 ] || fail "the link trace is empty: nothing proves what was linked"
[ "$ndeb" -gt 0 ] || fail "the link trace names no Debian library: the trace is broken"
echo "source offer complete: $n linked libraries ($ndeb from Debian), each with its source and licence text"
