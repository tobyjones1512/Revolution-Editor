#!/bin/sh
# Translates sample.swift and the starter game to C, compiles them with the real runtime against
# host stand-ins for libogc (including a software GX backend), and runs simulated sessions.
set -e
cd "$(dirname "$0")/../.."
OUT=${OUT:-/tmp/hbswift}
H="Revolution IDE/Core/Homebrew"
F="Revolution IDE/Core/Formats"
swiftc -parse-as-library -o /tmp/hbswiftgen \
  "$H/UIDocument.swift" "$H/UICodegen.swift" "$H/NodeGraph.swift" "$H/NodeGraphTools.swift" "$H/WiiUIRuntime.swift" "$H/WuiRuntime.swift" "$H/HomebrewSamples.swift" \
  "$H/SwiftAST.swift" "$H/SwiftLexer.swift" "$H/SwiftParser.swift" "$H/SwiftTypes.swift" "$H/SwiftTranslator.swift" "$H/SwiftTranslator+Stmt.swift" "$H/SwiftTranslator+Expr.swift" "$H/SwiftTranslator+Calls.swift" "$H/SwiftTranslator+Collections.swift" "$H/SwiftBuiltins.swift" "$H/SwiftTranslator+SwiftUI.swift" "$H/SwiftEmitter.swift" "$F/TextureCodec.swift" "$F/AudioFileImport.swift" "Revolution IDE/Core/BinaryIO.swift" \
  Tests/SwiftToCCheck/main.swift
/tmp/hbswiftgen "$OUT" Tests/SwiftToCCheck/sample.swift Tests/SwiftToCCheck/language.swift Tests/SwiftToCCheck/swiftui.swift
HOST="Tests/HostStubs/wgfx_host.c Tests/HostStubs/host_platform.c"
CC="clang -Wall -Wextra -Werror -std=gnu11 -ITests/HostStubs"
$CC -I"$OUT" -o "$OUT/host" "$OUT/wiiui.c" "$OUT/ui_generated.c" "$OUT/swift_generated.c" $HOST Tests/SwiftToCCheck/host_main.c -lm
"$OUT/host"
echo "--- language features"
$CC -I"$OUT/lang" -o "$OUT/lang/host" "$OUT/lang/wiiui.c" "$OUT/lang/ui_generated.c" "$OUT/lang/swift_generated.c" $HOST Tests/SwiftToCCheck/host_lang_main.c -lm
"$OUT/lang/host"
echo "--- SwiftUI"
$CC -I"$OUT/swiftui" -o "$OUT/swiftui/host" "$OUT/swiftui/wiiui.c" "$OUT/swiftui/ui_generated.c" "$OUT/swiftui/swift_generated.c" "$OUT/swiftui/wui.c" $HOST Tests/SwiftToCCheck/host_swiftui_main.c -lm
"$OUT/swiftui/host" "$OUT"
echo "--- SwiftUI template sample"
$CC -I"$OUT/swiftui_template" -o "$OUT/swiftui_template/host" "$OUT/swiftui_template/wiiui.c" "$OUT/swiftui_template/ui_generated.c" "$OUT/swiftui_template/swift_generated.c" "$OUT/swiftui_template/wui.c" $HOST Tests/SwiftToCCheck/host_template_main.c -lm
"$OUT/swiftui_template/host" "$OUT"
echo "--- starter game in Swift"
$CC -I"$OUT/game" -o "$OUT/game/host_swift" "$OUT/game/wiiui.c" "$OUT/game/ui_generated.c" "$OUT/game/swift_generated.c" $HOST Tests/SwiftToCCheck/host_game_main.c -lm
"$OUT/game/host_swift" "$OUT/swift_game.ppm"
echo "--- starter game in C"
rm -rf "$OUT/gc" && mkdir -p "$OUT/gc/generated"
cp "$OUT/game/"*.h "$OUT/game/wiiui.c" "$OUT/game/ui_generated.c" "$OUT/gc/generated/"
cp "$OUT/game/game_c.c" "$OUT/gc/game_c.c"
$CC -Dmain=game_c_main -I"$OUT/gc/generated" -c "$OUT/gc/game_c.c" -o "$OUT/gc/game_c.o"
$CC -I"$OUT/gc/generated" -o "$OUT/gc/host_c" "$OUT/gc/generated/wiiui.c" "$OUT/gc/generated/ui_generated.c" "$OUT/gc/game_c.o" $HOST Tests/SwiftToCCheck/host_game_main.c -lm
"$OUT/gc/host_c" "$OUT/c_game.ppm"
