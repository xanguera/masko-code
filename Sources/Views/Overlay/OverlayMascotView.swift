import SwiftUI
import AVKit
import AppKit

/// SwiftUI content view for the overlay panel — plays a looping HEVC video with alpha transparency.
struct OverlayMascotView: View {
    let url: URL
    let onClose: () -> Void
    let onResize: (OverlaySize) -> Void

    var body: some View {
        MascotVideoView(url: url)
            .contextMenu {
                Menu("Size") {
                    Button("Small (100)") { onResize(.small) }
                    Button("Medium (150)") { onResize(.medium) }
                    Button("Large (200)") { onResize(.large) }
                    Button("Extra Large (300)") { onResize(.extraLarge) }
                }
                Divider()
                Button("Close Mascot") { onClose() }
            }
    }
}

enum OverlaySize: Int, CaseIterable {
    case small = 100
    case medium = 150
    case large = 200
    case extraLarge = 300

    var cgSize: CGSize {
        CGSize(width: rawValue, height: rawValue)
    }
}
