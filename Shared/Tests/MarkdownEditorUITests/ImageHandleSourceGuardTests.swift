import Foundation
import XCTest

/// The pointer's promise, guarded at the source.
///
/// What went wrong could not be caught by testing arithmetic. The overlay
/// worked out the region that changes the cursor in one place and the region
/// that starts a drag in another, each with its own inset literal, and they
/// differed by 3pt — so there was a ring around every handle where the pointer
/// stayed an arrow and the drag started anyway. Both answers were "correct";
/// they were just not the same answer.
///
/// Arithmetic tests cannot see that, because once both callers ask the same
/// function they agree by construction and the test is a tautology. The real
/// property is structural: every question the pointer asks about a corner goes
/// through one function. That is what this reads the source to check.
final class ImageHandleSourceGuardTests: XCTestCase {
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // MarkdownEditorUITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // Shared
            .deletingLastPathComponent()  // repository root
    }

    private static var overlaySource: URL {
        repositoryRoot
            .appendingPathComponent("macOS/Sources/MarkdownEditor")
            .appendingPathComponent("MarkdownImageHandleOverlay.swift")
    }

    private func source() throws -> String {
        try XCTUnwrap(
            try? String(contentsOf: Self.overlaySource, encoding: .utf8),
            "Missing \(Self.overlaySource.path)"
        )
    }

    /// The body of `func name(`, brace-matched.
    private func body(of name: String, in source: String) throws -> String {
        guard let declaration = source.range(of: "func \(name)(") else {
            XCTFail("No `func \(name)(` in the overlay")
            return ""
        }
        guard
            let open = source[declaration.upperBound...].firstIndex(of: "{")
        else {
            XCTFail("`\(name)` has no body")
            return ""
        }
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: open)..<index])
                }
            }
            index = source.index(after: index)
        }
        XCTFail("`\(name)` has an unbalanced body")
        return ""
    }

    /// Everything the pointer asks about a corner asks the same function.
    func testCursorAndClickAgreeOnWhereTheHandlesAre() throws {
        let source = try source()
        // `resetCursorRects` chooses the shape; `hitTest` decides whether the
        // click is the overlay's at all; `mouseDown` decides which corner moves.
        // All three have to be looking at the same rectangles.
        XCTAssertTrue(
            try self.body(of: "resetCursorRects", in: source).contains("cursorRects()"),
            "`resetCursorRects` must register exactly the rects `cursorRects()` reports"
        )
        for method in ["cursorRects", "hitTest", "mouseDown"] {
            let body = try self.body(of: method, in: source)
            XCTAssertFalse(body.isEmpty, "`\(method)` is empty")
            XCTAssertTrue(
                body.contains("handleHitRect") || body.contains("corner(at:"),
                """
                `\(method)` does not go through the shared handle geometry, so \
                the cursor and the click can disagree about where a corner is.
                """
            )
        }
    }

    /// No pointer method may quietly widen a target by itself.
    ///
    /// This is the shape the bug actually took: an `insetBy(dx: -3, dy: -3)`
    /// written twice at the call sites and once, differently, in the cursor
    /// rects. Drawing may still inset — the outline is stroked half a point
    /// outside the picture — but nothing that answers the pointer may.
    func testTheOverlayDoesNotInventItsOwnTargetSizes() throws {
        let source = try source()
        for method in ["cursorRects", "hitTest", "mouseDown"] {
            let body = try self.body(of: method, in: source)
            XCTAssertFalse(
                body.contains("insetBy"),
                """
                `\(method)` resizes a rect itself. Handle targets come from \
                EditorImageGeometry.handleHitRect so every caller gets the same \
                one; a local inset is how the cursor and the click drifted \
                apart before.
                """
            )
        }
    }

    /// A cursor that is pushed for the duration of a drag has to be popped, or
    /// the stack grows by one every resize and the pointer never recovers.
    func testAPushedCursorIsAlwaysPopped() throws {
        let source = try source()
        let pushes = source.components(separatedBy: "cursor.push()").count - 1
        XCTAssertEqual(pushes, 1, "Only the start of a drag should push a cursor")
        XCTAssertTrue(
            source.contains("NSCursor.pop()"),
            "A pushed cursor is never popped"
        )
        // The pop is guarded by a flag rather than called blindly, because
        // `mouseUp` also arrives for clicks that never pushed anything.
        XCTAssertTrue(
            source.contains("isPushingCursor"),
            "The pop is not balanced against whether a push happened"
        )
        for method in ["mouseUp", "hide"] {
            let body = try self.body(of: method, in: source)
            XCTAssertTrue(
                body.contains("popCursorIfNeeded"),
                "`\(method)` can end a drag without restoring the cursor"
            )
        }
    }
}
