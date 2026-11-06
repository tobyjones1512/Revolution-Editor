#!/bin/sh
# Type-checks the generated device code (wgfx_gx.c, wiiui.c, translated Swift) against libogc's real
# headers (fetched into /tmp), so wrong function names, argument counts and types are caught without a
# devkitPPC toolchain. Errors inside libogc's own inline-assembly header (cast.h) are expected on a Mac.
#   Tests/HostStubs/check_real_headers.sh <dir of generated files>   (e.g. /tmp/hbswift/game)
set -e
DIR=${1:-/tmp/hbswift/game}
[ -d /tmp/libogc ] || git clone --depth 1 https://github.com/devkitPro/libogc.git /tmp/libogc >/dev/null 2>&1
mkdir -p /tmp/hdrstubs && printf '#include <stdlib.h>\nvoid *memalign(size_t, size_t);\n' > /tmp/hdrstubs/malloc.h
FAIL=0
for f in wgfx_gx.c wiiui.c ui_generated.c swift_generated.c wui.c; do
  [ -f "$DIR/$f" ] || continue
  OUT=$(clang -fsyntax-only -w -std=gnu11 -DGEKKO -DHW_RVL -I"$DIR" -I/tmp/hdrstubs -I/tmp/libogc/gc "$DIR/$f" 2>&1 | grep -E "error:" | grep -v "ogc/cast.h" || true)
  if [ -n "$OUT" ]; then echo "FAIL $f"; echo "$OUT"; FAIL=1; else echo "ok   $f against libogc headers"; fi
done
exit $FAIL
