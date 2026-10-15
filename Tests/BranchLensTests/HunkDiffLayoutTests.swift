@testable import BranchLens
import AppKit
import SwiftUI
import XCTest

final class HunkDiffLayoutTests: XCTestCase {
    @MainActor
    func testLongHunkExpandsToFullHeight() async throws {
        try await assertHunkBodyLayout(additions: 143)
    }

    @MainActor
    func testShortHunkKeepsExpandedBody() async throws {
        try await assertHunkBodyLayout(additions: 12)
    }

    @MainActor
    private func assertHunkBodyLayout(additions: Int) async throws {
        let text = (["@@ -2305,3 +2305,\(additions + 3) @@ pub fn critter_plugin(app: &mut App) {",
                     "     app.add_systems(Update, critters);", " }", " "]
                    + (1...additions).map { "+let value\($0) = \($0);" }).joined(separator: "\n")
        let view = HunkDiffView(
            text: text,
            path: "src/creatures.rs",
            searchQuery: "",
            actionTitle: "Stage Hunk",
            onHunkAction: { _ in }
        )
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        defer { window.close() }

        // Allow SwiftUI to lay out the lazy hunk card and finish highlighting.
        for _ in 0..<20 {
            hosting.layoutSubtreeIfNeeded()
            if let body = diffBody(in: hosting),
               let textView = body.documentView as? NSTextView,
               !textView.string.isEmpty,
               body.frame.height >= textView.frame.height - 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        hosting.layoutSubtreeIfNeeded()
        let body = try XCTUnwrap(diffBody(in: hosting))
        XCTAssertFalse(body.hasVerticalScroller, "Only the outer container should scroll vertically")
        XCTAssertGreaterThan(body.frame.height, 100, "The hunk body must remain visible in the outer lazy stack")
        let document = try XCTUnwrap(body.documentView)
        XCTAssertGreaterThanOrEqual(body.frame.height, document.frame.height - 1, "The whole hunk must fit without internal vertical scrolling")
        if additions > 140 {
            XCTAssertGreaterThan(body.frame.height, hosting.frame.height)
            let outerScroll = try XCTUnwrap(body.enclosingScrollView)
            XCTAssertGreaterThan(try XCTUnwrap(outerScroll.documentView).frame.height, outerScroll.contentView.bounds.height)
        }
        let rendered = try XCTUnwrap(body.documentView as? NSTextView).string
        XCTAssertTrue(rendered.contains("let value1 = 1;"))
        XCTAssertTrue(rendered.contains("let value\(additions) = \(additions);"))
        XCTAssertTrue(rendered.contains("2308"), "The first added line keeps its source line number")
    }

    @MainActor
    private func diffBody(in view: NSView) -> DiffScrollView.FittingScrollView? {
        if let body = view as? DiffScrollView.FittingScrollView { return body }
        return view.subviews.lazy.compactMap { self.diffBody(in: $0) }.first
    }
}
