#!/usr/bin/env bash
# List what the stock (prebuilt) ffmpeg has that the patched build does not,
# and the reverse, so a dropped codec is a written-down fact rather than a
# surprise. Same architecture on both sides.
#
#   compare-stock.sh <stock ffmpeg> <new ffmpeg> <outdir>
#
# Writes <outdir>/stock-only.txt, new-only.txt (one "<category> <name>" per
# line) and <outdir>/DROPPED.md (the readable summary; the committed DROPPED.md
# is that summary with the reasons added by hand).
set -euo pipefail
STOCK="$1"; NEW="$2"; OUT="$3"
mkdir -p "$OUT"

# The listings come in three shapes:
#   - encoders, decoders, muxers, demuxers, filters, devices: a legend, a dashed
#     line, then one row per component with the name in column 2;
#   - protocols: "Input:" / "Output:" sections of one name per line (reported as
#     input:<name> / output:<name>, since a protocol can exist in one direction);
#   - bsfs, hwaccels: a title line, then one name per line.
# The last two have no dashed line, so a parser that waits for one sees nothing
# and the comparison for those categories would be silently empty.
export LC_ALL=C
names() { # <bin> <category>
  case "$2" in
    protocols)
      "$1" -hide_banner -protocols 2>/dev/null | awk '/^Input:/ {d="input:"; next} /^Output:/ {d="output:"; next} d && NF==1 {print d $1}' | sort -u ;;
    bsfs|hwaccels)
      "$1" -hide_banner "-$2" 2>/dev/null | awk 'NR>1 && NF==1 && $0 !~ /:$/ {print $1}' | sort -u ;;
    *)
      "$1" -hide_banner "-$2" 2>/dev/null | awk '/^ *-+$/ {body=1; next} body && NF>=2 {print $2}' | sort -u ;;
  esac
}
categories=(encoders decoders muxers demuxers filters protocols bsfs hwaccels devices)
: > "$OUT/stock-only.txt"; : > "$OUT/new-only.txt"
for c in "${categories[@]}"; do
  names "$STOCK" "$c" > "$OUT/stock-$c.txt" || true
  names "$NEW"   "$c" > "$OUT/new-$c.txt" || true
  comm -23 "$OUT/stock-$c.txt" "$OUT/new-$c.txt" | sed "s/^/$c /" >> "$OUT/stock-only.txt"
  comm -13 "$OUT/stock-$c.txt" "$OUT/new-$c.txt" | sed "s/^/$c /" >> "$OUT/new-only.txt"
done

# The configure flags that explain it.
conf() { "$1" -hide_banner -buildconf 2>/dev/null | tr -s ' \t' '\n\n' | grep -E '^--(enable|disable)-' | sort -u; }
conf "$STOCK" > "$OUT/stock-flags.txt"; conf "$NEW" > "$OUT/new-flags.txt"
{
  echo "# Stock prebuilt vs the patched build"
  echo
  echo "Stock: \`$("$STOCK" -version | head -1)\`"
  echo
  echo "Patched: \`$("$NEW" -version | head -1)\`"
  echo
  echo "## Configure flags the stock build had and this one does not"
  echo
  comm -23 "$OUT/stock-flags.txt" "$OUT/new-flags.txt" | sed 's/^/- `/; s/$/`/'
  echo
  echo "## Components in the stock build and not in this one ($(wc -l < "$OUT/stock-only.txt" | tr -d ' '))"
  echo
  for c in "${categories[@]}"; do
    list="$(grep "^$c " "$OUT/stock-only.txt" | cut -d' ' -f2 | tr '\n' ' ' || true)"
    [ -z "$list" ] || { echo "- **$c:** $list"; }
  done
  echo
  echo "## Components in this build and not in the stock one ($(wc -l < "$OUT/new-only.txt" | tr -d ' '))"
  echo
  for c in "${categories[@]}"; do
    list="$(grep "^$c " "$OUT/new-only.txt" | cut -d' ' -f2 | tr '\n' ' ' || true)"
    [ -z "$list" ] || { echo "- **$c:** $list"; }
  done
} > "$OUT/DROPPED.md"
cat "$OUT/DROPPED.md"
