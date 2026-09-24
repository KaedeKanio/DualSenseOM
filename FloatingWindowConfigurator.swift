import AppKit
import SwiftUI

struct FloatingWindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { FloatingWindowLevelView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FloatingWindowLevelView)?.applyFloatingLevel()
    }
}

private final class FloatingWindowLevelView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFloatingLevel()
    }

    func applyFloatingLevel() {
        window?.level = .floating
        window?.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }
}
