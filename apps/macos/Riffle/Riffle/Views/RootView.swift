// The panel content: the setup screen or the search. Reports its height to the panel controller.

import RiffleKit
import SwiftUI

struct RootView: View {
    let model: SearchModel
    let state: PanelState
    let close: () -> Void
    let open: (URL) -> Void
    let setHeight: (CGFloat) -> Void

    var body: some View {
        Group {
            if model.needsSetup {
                SetupView(model: model)
            } else {
                SearchView(model: model, state: state, open: open)
            }
        }
        .frame(width: Theme.panelWidth)
        .fixedSize(horizontal: false, vertical: true)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { setHeight($0) }
        .foregroundStyle(Theme.text)
        .tint(Theme.ink)
        .onExitCommand {
            if !model.escape() { close() }
        }
        // Keeps the content at the top while the panel catches up with a new height.
        // minHeight 0 lets the frame be shorter than taller content. Without it, the frame grows to the content
        // height, and the hosting view centers it: the top jumps up by half the change, then slides back.
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(Theme.panel.opacity(0.92))
    }
}
