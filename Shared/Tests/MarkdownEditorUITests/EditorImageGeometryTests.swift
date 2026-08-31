import CoreGraphics
import XCTest

@testable import MarkdownEditorUI

final class EditorImageGeometryTests: XCTestCase {
    // MARK: - Where the picture is

    /// The case the whole change exists for: an image on a line taller than
    /// itself. The line box starts above the picture and ends below it, so a
    /// rect taken from the line would claim blank space on both sides.
    func testAttachmentRectIgnoresTheHeightOfTheLine() {
        // A 60pt line whose baseline sits 48pt down, holding a 40pt image.
        let rect = EditorImageGeometry.attachmentRect(
            lineFragment: CGRect(x: 10, y: 100, width: 500, height: 60),
            glyphLocation: CGPoint(x: 4, y: 48),
            attachmentSize: CGSize(width: 80, height: 40),
            containerOrigin: .zero
        )
        // Bottom edge on the baseline, top edge 40pt above it.
        XCTAssertEqual(rect.minY, 108)
        XCTAssertEqual(rect.maxY, 148)
        XCTAssertEqual(rect.minX, 14)
        XCTAssertEqual(rect.width, 80)
        XCTAssertEqual(rect.height, 40)
        // Strictly inside the line it sits on, which is the point.
        XCTAssertGreaterThan(rect.minY, 100)
        XCTAssertLessThan(rect.maxY, 160)
    }

    func testAttachmentRectAddsTheContainerOrigin() {
        let rect = EditorImageGeometry.attachmentRect(
            lineFragment: CGRect(x: 0, y: 0, width: 500, height: 50),
            glyphLocation: CGPoint(x: 0, y: 50),
            attachmentSize: CGSize(width: 100, height: 50),
            containerOrigin: CGPoint(x: 20, y: 8)
        )
        XCTAssertEqual(rect.origin, CGPoint(x: 20, y: 8))
    }

    /// The 4pt bug, as an assertion.
    ///
    /// `NSTextAttachment.bounds.origin` does not move the picture — the layout
    /// manager has already applied it by the time it reports a glyph location.
    /// Applying it again put every handle 4pt below the corner it was holding,
    /// because the renderer sets a negative offset. The rect must depend on the
    /// size and nothing else.
    func testTheBaselineOffsetIsNotAppliedTwice() {
        let fragment = CGRect(x: 0, y: 0, width: 500, height: 60)
        let location = CGPoint(x: 0, y: 50)
        let size = CGSize(width: 30, height: 30)
        let rect = EditorImageGeometry.attachmentRect(
            lineFragment: fragment,
            glyphLocation: location,
            attachmentSize: size,
            containerOrigin: .zero
        )
        // The glyph location is the picture's bottom edge, whatever offset the
        // renderer asked for, so the top is exactly one height above it.
        XCTAssertEqual(rect.maxY, 50)
        XCTAssertEqual(rect.minY, 20)
    }

    // MARK: - Handles

    func testHandlesSitOnTheCornersTheyAreNamedFor() {
        let frame = CGRect(x: 100, y: 200, width: 300, height: 150)
        let side = EditorImageGeometry.handleSide
        for corner in EditorImageCorner.allCases {
            let rect = EditorImageGeometry.handleRect(corner, in: frame)
            XCTAssertEqual(rect.width, side)
            XCTAssertEqual(rect.height, side)
            // Centred on the corner: half in, half out.
            XCTAssertEqual(
                CGPoint(x: rect.midX, y: rect.midY),
                corner.position(in: frame)
            )
        }
        XCTAssertEqual(
            EditorImageCorner.topLeading.position(in: frame),
            CGPoint(x: 100, y: 200)
        )
        XCTAssertEqual(
            EditorImageCorner.bottomTrailing.position(in: frame),
            CGPoint(x: 400, y: 350)
        )
    }

    func testTheHitAreaIsLargerThanTheDotButStillLocal() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 400)
        let drawn = EditorImageGeometry.handleRect(.topLeading, in: frame)
        let hit = EditorImageGeometry.handleHitRect(.topLeading, in: frame)
        XCTAssertTrue(hit.contains(drawn))
        XCTAssertGreaterThan(hit.width, drawn.width)
        // The middle of a large picture is text, not a handle.
        XCTAssertNil(
            EditorImageGeometry.corner(at: CGPoint(x: 200, y: 200), in: frame)
        )
    }

    /// On a picture small enough that two widened targets overlap, the overlap
    /// has to go to the nearer corner or one of them cannot be reached.
    func testOverlappingTargetsGoToTheNearerCorner() {
        let tiny = CGRect(x: 0, y: 0, width: 14, height: 14)
        XCTAssertEqual(
            EditorImageGeometry.corner(at: CGPoint(x: 1, y: 1), in: tiny),
            .topLeading
        )
        XCTAssertEqual(
            EditorImageGeometry.corner(at: CGPoint(x: 13, y: 13), in: tiny),
            .bottomTrailing
        )
        XCTAssertEqual(
            EditorImageGeometry.corner(at: CGPoint(x: 13, y: 1), in: tiny),
            .topTrailing
        )
        XCTAssertEqual(
            EditorImageGeometry.corner(at: CGPoint(x: 1, y: 13), in: tiny),
            .bottomLeading
        )
    }

    // MARK: - Structural guards

    func testTheIOSOverlayIsSizedToTheContentNotTheVisibleRect() throws {
        // A UITextView is a scroll view, so its subviews live in content
        // coordinates while `bounds` is only what is on screen. Sizing the
        // overlay to `bounds` leaves every handle below the first screenful
        // outside it, and UIKit refuses hit tests outside a view's bounds — so
        // those handles can be seen and never touched. It reads as "resize
        // doesn't work", but only after scrolling, which is exactly the kind of
        // fault that survives a demo.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarkdownEditorUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("iOS/Sources/MarkdownEditorIOS/MarkdownRichTextEditor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(
            source.contains("overlay.frame = CGRect(origin: .zero, size: textView.contentSize)"),
            "the iOS image overlay must be sized to the text view's contentSize"
        )
        // Sizing it once at setup is not enough, and neither is KVO: measured
        // against the running app, contentSize changes during layout without
        // reliably notifying, so a tap that found the picture at y=444 saw a
        // contentSize of 395. It has to be re-sized every time it is shown.
        XCTAssertGreaterThanOrEqual(
            source.components(separatedBy: "size: textView.contentSize").count - 1, 3,
            "the overlay must be re-sized wherever it is shown, not only at setup"
        )
        XCTAssertFalse(
            source.contains("overlay.frame = textView.bounds"),
            "sizing the overlay to bounds makes handles below the fold untouchable"
        )
    }

    func testACommittedIOSMoveDropsTheCachedSelectionRect() throws {
        // The overlay caches the picture's rect and only refreshes it on a tap
        // or a resize. A committed move relays the picture out somewhere else,
        // so putting the frame back after the drag draws it around the space
        // the picture has just left. Seen on a device: after moving a picture
        // above the first paragraph the frame and handles stayed about fifty
        // points below it, sitting over the text.
        //
        // A move that never found a destination is a different case — nothing
        // changed, so the frame must come back.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarkdownEditorUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("iOS/Sources/MarkdownEditorIOS/MarkdownImageOverlayView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(
            source.components(separatedBy: "func endMove()").last,
            "MarkdownImageOverlayView must still have an endMove"
        )
        let committed = try XCTUnwrap(
            body.components(separatedBy: "guard !committed else {").last
        )
        XCTAssertTrue(
            committed.hasPrefix("\n            show(range: nil, rect: nil)"),
            "a committed move must clear the selection rather than restore a stale frame"
        )
        XCTAssertTrue(
            body.contains("frameLayer.isHidden = false"),
            "a move that did not commit must put the frame back"
        )
    }

    func testOnlyTheIOSLongPressRefusesTouchesAwayFromAPicture() throws {
        // The long press has to refuse touches that miss a picture, or
        // UITextView's own long press wins and a picture can never be picked
        // up. Applying the same filter to the *tap* is a regression that is
        // easy to write and hard to notice: the tap is what deselects, so
        // filtering it means a selected picture keeps its frame forever, no
        // matter where you tap. Caught on a device only because it was looked
        // for.
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MarkdownEditorUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Shared
            .deletingLastPathComponent()   // the repository root
            .appendingPathComponent("iOS/Sources/MarkdownEditorIOS/MarkdownRichTextEditor.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let body = try XCTUnwrap(
            source.components(separatedBy: "shouldReceive touch: UITouch").last,
            "the coordinator must still decide which touches its recognisers see"
        )
        XCTAssertTrue(
            body.contains("guard recogniser is UILongPressGestureRecognizer else { return true }"),
            "only the long press may refuse a touch; filtering the tap breaks deselecting"
        )
    }

    // MARK: - Touch targets

    func testAFingerTargetIsAtLeastTheComfortableTapSize() {
        // A picture large enough that the cap does not apply.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        for corner in EditorImageCorner.allCases {
            let rect = EditorImageGeometry.touchHitRect(corner, in: frame)
            XCTAssertGreaterThanOrEqual(
                rect.width, EditorImageGeometry.touchTarget - 0.001,
                "\(corner) is smaller than a fingertip"
            )
            XCTAssertGreaterThanOrEqual(
                rect.height, EditorImageGeometry.touchTarget - 0.001,
                "\(corner) is smaller than a fingertip"
            )
        }
    }

    func testAFingerTargetIsBiggerThanAPointerTarget() {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        for corner in EditorImageCorner.allCases {
            XCTAssertGreaterThan(
                EditorImageGeometry.touchHitRect(corner, in: frame).width,
                EditorImageGeometry.handleHitRect(corner, in: frame).width,
                "a finger needs more room than a pointer, not less"
            )
        }
    }

    func testASmallPictureKeepsAMiddleToTakeHoldOf() {
        // Four fixed 44pt targets meet in the middle of anything narrow. A
        // picture that cannot be grabbed in the middle can be resized but never
        // moved, which is a worse fault than a target that is hard to hit.
        for side in [24.0, 32.0, 48.0, 64.0] as [CGFloat] {
            let frame = CGRect(x: 0, y: 0, width: side, height: side)
            XCTAssertNil(
                EditorImageGeometry.touchCorner(
                    at: CGPoint(x: frame.midX, y: frame.midY), in: frame
                ),
                "the corners meet in the middle at \(side)pt"
            )
        }
    }

    func testASmallPictureStillHasReachableCorners() {
        for side in [24.0, 32.0, 48.0, 64.0] as [CGFloat] {
            let frame = CGRect(x: 0, y: 0, width: side, height: side)
            for corner in EditorImageCorner.allCases {
                let at = corner.position(in: frame)
                XCTAssertNotNil(
                    EditorImageGeometry.touchCorner(at: at, in: frame),
                    "\(corner) is unreachable at \(side)pt"
                )
            }
        }
    }

    func testAFingerTargetPrefersTheCornerBeingPointedAt() {
        // Where two widened targets overlap, the overlap has to go to the
        // corner actually being aimed at or one of them becomes unreachable.
        let frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        XCTAssertEqual(
            EditorImageGeometry.touchCorner(at: CGPoint(x: 0, y: 0), in: frame),
            .topLeading
        )
        XCTAssertEqual(
            EditorImageGeometry.touchCorner(at: CGPoint(x: 60, y: 60), in: frame),
            .bottomTrailing
        )
    }

    func testTheOverlayIsInsetEnoughToDrawEveryHandle() {
        let frame = CGRect(
            x: EditorImageGeometry.overlayInset,
            y: EditorImageGeometry.overlayInset,
            width: 120,
            height: 90
        )
        let bounds = CGRect(
            x: 0,
            y: 0,
            width: frame.width + EditorImageGeometry.overlayInset * 2,
            height: frame.height + EditorImageGeometry.overlayInset * 2
        )
        for corner in EditorImageCorner.allCases {
            XCTAssertTrue(
                bounds.contains(
                    EditorImageGeometry.handleHitRect(corner, in: frame)
                ),
                "\(corner)'s target is clipped by the overlay"
            )
        }
    }

    // MARK: - Dragging

    func testEachCornerGrowsWhenDraggedAwayFromTheImage() {
        let start = CGRect(x: 0, y: 0, width: 200, height: 100)
        let outward: [EditorImageCorner: CGPoint] = [
            .topLeading: CGPoint(x: -10, y: -10),
            .topTrailing: CGPoint(x: 10, y: -10),
            .bottomLeading: CGPoint(x: -10, y: 10),
            .bottomTrailing: CGPoint(x: 10, y: 10)
        ]
        for (corner, delta) in outward {
            let grown = EditorImageGeometry.draggedWidth(
                from: start,
                corner: corner,
                deltaX: delta.x,
                deltaY: delta.y
            )
            XCTAssertGreaterThan(grown, start.width, "\(corner) shrank")
            let shrunk = EditorImageGeometry.draggedWidth(
                from: start,
                corner: corner,
                deltaX: -delta.x,
                deltaY: -delta.y
            )
            XCTAssertLessThan(shrunk, start.width, "\(corner) grew")
        }
    }

    /// A drag mostly sideways should follow the pointer sideways, and a drag
    /// mostly vertical should follow it vertically — compared in width, since
    /// a 2:1 image moves twice as far horizontally for the same size change.
    func testTheLargerMovementWins() {
        let wide = CGRect(x: 0, y: 0, width: 200, height: 100)
        // 40 across, 2 down: horizontal wins outright.
        XCTAssertEqual(
            EditorImageGeometry.draggedWidth(
                from: wide,
                corner: .bottomTrailing,
                deltaX: 40,
                deltaY: 2
            ),
            240
        )
        // 2 across, 40 down: vertical wins, and 40pt of height on a 2:1 image
        // is 80pt of width.
        XCTAssertEqual(
            EditorImageGeometry.draggedWidth(
                from: wide,
                corner: .bottomTrailing,
                deltaX: 2,
                deltaY: 40
            ),
            280
        )
    }

    func testADragCannotShrinkAnImageAway() {
        let start = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertEqual(
            EditorImageGeometry.draggedWidth(
                from: start,
                corner: .bottomTrailing,
                deltaX: -10_000,
                deltaY: -10_000
            ),
            EditorImageGeometry.minimumSide
        )
    }

    func testADegenerateFrameDoesNotDivideByZero() {
        let width = EditorImageGeometry.draggedWidth(
            from: .zero,
            corner: .bottomTrailing,
            deltaX: 50,
            deltaY: 50
        )
        XCTAssertEqual(width, EditorImageGeometry.minimumSide)
        XCTAssertFalse(width.isNaN)
    }
}
