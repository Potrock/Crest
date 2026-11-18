import AppKit
import SwiftUI

/// macOS owns a real column-resize pointer, so the divider can say what it does
/// before anyone grabs it.
///
/// The pointer comes from an AppKit tracking area rather than SwiftUI's
/// `pointerStyle(_:)`. A pointer style makes the hosting view hit-test its
/// whole SwiftUI hierarchy on every mouse move to learn which style is under
/// the pointer, and the sidebar's handle is always on screen, so every move
/// anywhere in the window paid for a walk of every sidebar row. A tracking
/// area answers only while the pointer is inside the handle. Its owner hears
/// those moves although it takes no clicks, as `BrowserSplitCardHoverTrackingView`
/// does; cursor rectangles would not work here, because the hosting view
/// answers the cursor for everything inside it.
struct BrowserPlatformColumnResizePointerModifier: ViewModifier {
    // MARK: - Types

    /// A view that takes no clicks and shows the column-resize pointer while
    /// the pointer is over it.
    private struct CursorArea: NSViewRepresentable {
        final class View: NSView {
            private var trackingArea: NSTrackingArea?

            override func hitTest(_ point: NSPoint) -> NSView? { nil }

            override func updateTrackingAreas() {
                super.updateTrackingAreas()
                if let trackingArea { removeTrackingArea(trackingArea) }
                let area = NSTrackingArea(
                    // `.inVisibleRect` supplies the rect, so this one is ignored.
                    rect: .zero,
                    options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
                    owner: self
                )
                addTrackingArea(area)
                trackingArea = area
            }

            override func mouseEntered(with event: NSEvent) { NSCursor.columnResize.set() }
            override func mouseMoved(with event: NSEvent) { NSCursor.columnResize.set() }
            override func cursorUpdate(with event: NSEvent) { NSCursor.columnResize.set() }
            override func mouseExited(with event: NSEvent) { NSCursor.arrow.set() }
        }

        func makeNSView(context: Context) -> View { View() }
        func updateNSView(_ nsView: View, context: Context) {}
    }

    // MARK: - Actions - Presentation

    func body(content: Content) -> some View {
        content.background(CursorArea())
    }
}
