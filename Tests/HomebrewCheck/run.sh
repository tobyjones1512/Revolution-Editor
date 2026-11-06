#!/bin/sh
# Template + generator check, then a syntax check of the UI app template's own main.c and the
# generated C against host stubs of libogc.
set -e
cd "$(dirname "$0")/../.."
H="Revolution IDE/Core/Homebrew"
swiftc -parse-as-library -o /tmp/hbcheck "Revolution IDE/Core/Workbench/Homebrew.swift" "Revolution IDE/Core/Workbench/HomebrewPackage.swift" \
  "$H/UIDocument.swift" "$H/UICodegen.swift" "$H/NodeGraph.swift" "$H/NodeGraphTools.swift" "$H/NodeCodegen.swift" "$H/WiiUIRuntime.swift" "$H/HomebrewGenerator.swift" "$H/SwiftAST.swift" "$H/SwiftLexer.swift" "$H/SwiftParser.swift" "$H/SwiftTypes.swift" "$H/SwiftTranslator.swift" "$H/SwiftTranslator+Stmt.swift" "$H/SwiftTranslator+Expr.swift" "$H/SwiftTranslator+Calls.swift" "$H/SwiftTranslator+Collections.swift" "$H/SwiftBuiltins.swift" "$H/SwiftTranslator+SwiftUI.swift" "$H/WuiRuntime.swift" "$H/SwiftEmitter.swift" "$H/HomebrewSamples.swift" "Revolution IDE/Core/Formats/TextureCodec.swift" "Revolution IDE/Core/Formats/AudioFileImport.swift" "Revolution IDE/Core/BinaryIO.swift" \
  Tests/HomebrewCheck/main.swift
rm -rf /tmp/hbapp
rm -rf /tmp/hbgame /tmp/hbsui; HB_KEEP=/tmp/hbapp HB_KEEP_GAME=/tmp/hbgame HB_KEEP_SUI=/tmp/hbsui /tmp/hbcheck
clang -fsyntax-only -Wall -Wextra -Werror -std=gnu11 -ITests/HostStubs -I/tmp/hbapp/source/generated \
  /tmp/hbapp/source/main.c /tmp/hbapp/source/generated/wiiui.c /tmp/hbapp/source/generated/ui_generated.c /tmp/hbapp/source/generated/logic_generated.c
echo "C syntax OK"
Tests/HostStubs/check_real_headers.sh /tmp/hbgame/source/generated
Tests/HostStubs/check_real_headers.sh /tmp/hbsui/source/generated
