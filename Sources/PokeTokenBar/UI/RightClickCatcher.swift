import AppKit
import SwiftUI

/// Runs `action` on a right-click, without a menu. Every other event goes through to the views below,
/// so a button or menu under it keeps working with a left-click.
struct RightClickCatcher: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.action = action
        return view
    }

    func updateNSView(_ view: CatcherView, context: Context) {
        view.action = action
    }

    final class CatcherView: NSView {
        var action: (() -> Void)?

        /// Claims only right-clicks; anything else falls through to the SwiftUI views underneath.
        override func hitTest(_ point: NSPoint) -> NSView? {
            switch NSApp.currentEvent?.type {
            case .rightMouseDown, .rightMouseUp: return super.hitTest(point)
            default: return nil
            }
        }

        override func rightMouseDown(with event: NSEvent) {
            action?()
        }

        /// No context menu: the right-click is the action.
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}
