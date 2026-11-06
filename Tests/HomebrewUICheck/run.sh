#!/bin/sh
# Generates the sample UI + node logic and the node-based game, compiles them with the real runtime
# against host stand-ins for libogc (including a software version of the GX backend), runs a
# simulated session, and leaves before.ppm / after.ppm / nodes_game.ppm in $OUT for a look.
set -e
cd "$(dirname "$0")/../.."
OUT=${OUT:-/tmp/hbui}
H="Revolution IDE/Core/Homebrew"
F="Revolution IDE/Core/Formats"
swiftc -parse-as-library -o /tmp/hbuigen \
  "$H/UIDocument.swift" "$H/UICodegen.swift" "$H/NodeGraph.swift" "$H/NodeGraphTools.swift" "$H/NodeCodegen.swift" "$H/WiiUIRuntime.swift" "$H/HomebrewSamples.swift" \
  "$F/TextureCodec.swift" "$F/AudioFileImport.swift" "Revolution IDE/Core/BinaryIO.swift" Tests/HomebrewUICheck/main.swift
/tmp/hbuigen "$OUT"
CC="clang -Wall -Wextra -Werror -std=gnu11 -ITests/HostStubs"
$CC -I"$OUT" -o "$OUT/host" "$OUT/wiiui.c" "$OUT/ui_generated.c" "$OUT/logic_generated.c" \
  Tests/HostStubs/wgfx_host.c Tests/HostStubs/host_platform.c Tests/HomebrewUICheck/host_main.c -lm
"$OUT/host" "$OUT"
$CC -I"$OUT" -I"$OUT/game" -o "$OUT/host_game" "$OUT/wiiui.c" "$OUT/game/ui_generated.c" "$OUT/game/logic_generated.c" \
  Tests/HostStubs/wgfx_host.c Tests/HostStubs/host_platform.c Tests/HomebrewUICheck/host_game_nodes_main.c -lm
"$OUT/host_game" "$OUT"
