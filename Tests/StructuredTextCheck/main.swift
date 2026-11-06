// JSON/XML helpers check: formatting keeps key order and strings intact, minify inverts it, and
// the outline follows source order.
//
//   swiftc -parse-as-library -o /tmp/structcheck "Revolution IDE/Core/Editor/CodeLanguage.swift" \
//     "Revolution IDE/Core/Editor/StructuredText.swift" Tests/StructuredTextCheck/main.swift && /tmp/structcheck

import Foundation

@main enum StructuredTextCheck {
    static func main() {
        let src = #"{"z":1,"a":{"s":"a, b: {\"q\"}","e":[],"o":{}},"list":[true,null,-1.5e3]}"#
        let pretty = StructuredText.pretty(src, .json)!
        print(pretty)
        precondition(pretty.contains("\"z\": 1") && pretty.range(of: "\"z\"")!.lowerBound < pretty.range(of: "\"list\"")!.lowerBound, "key order lost")
        precondition(pretty.contains(#""a, b: {\"q\"}""#), "string content changed")
        precondition(pretty.contains("\"e\": []") && pretty.contains("\"o\": {}"), "empty containers split")
        precondition(StructuredText.minify(pretty, .json) == src, "minify(pretty(x)) != x")
        let outline = StructuredText.outline(src, .json)
        precondition(outline.map(\.label) == ["z", "a", "list"], "outline order \(outline.map(\.label))")
        precondition(outline[1].children?.first?.value == #""a, b: {"q"}""#)
        precondition(outline[2].children?.count == 3)
        precondition(StructuredText.validate("{\"a\":", .json) != nil, "invalid JSON passed")
        let xml = "<wiidisc version=\"1\"><patch id=\"p\"><file disc=\"/a\" external=\"b\"/></patch></wiidisc>"
        precondition(StructuredText.validate(xml, .xml) == nil)
        precondition(StructuredText.validate("<a><b></a>", .xml) != nil, "invalid XML passed")
        let x = StructuredText.outline(xml, .xml)
        precondition(x.first?.label == "wiidisc" && x.first?.children?.first?.children?.first?.label == "file")
        precondition(StructuredText.pretty(xml, .xml)?.contains("\n") == true)
        print("ok")
    }
}
