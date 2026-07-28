import BranchLensCore
import XCTest

final class DiffParserTests: XCTestCase {
    func testParsesAdditionsAndDeletionsWithLineNumbers() {
        let diff = """
        diff --git a/a.swift b/a.swift
        --- a/a.swift
        +++ b/a.swift
        @@ -1,3 +1,4 @@
         import Foundation
        -let x = 1
        +let x = 2
        +let y = 3
         // end
        """

        let lines = DiffParser.parse(diff)
        XCTAssertTrue(lines.contains { $0.kind == .meta })
        XCTAssertTrue(lines.contains { $0.kind == .hunk })
        XCTAssertEqual(lines.filter { $0.kind == .deletion }.count, 1)
        XCTAssertEqual(lines.filter { $0.kind == .addition }.count, 2)

        let deletion = lines.first { $0.kind == .deletion }
        XCTAssertEqual(deletion?.code, "let x = 1")
        XCTAssertEqual(deletion?.oldLine, 2)

        let addition = lines.first { $0.kind == .addition && $0.code.contains("y = 3") }
        XCTAssertEqual(addition?.newLine, 3)
    }

    func testHighlighterFindsSwiftKeywords() {
        let tokens = CodeHighlighter.tokenize("let value = \"hi\" // note", path: "Sample.swift")
        XCTAssertTrue(tokens.contains { $0.kind == .keyword && $0.text == "let" })
        XCTAssertTrue(tokens.contains { $0.kind == .string && $0.text.contains("hi") })
        XCTAssertTrue(tokens.contains { $0.kind == .comment && $0.text.contains("note") })
    }
}
