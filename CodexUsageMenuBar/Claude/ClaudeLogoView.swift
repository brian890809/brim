import AppKit
import SwiftUI

struct ClaudeLogoView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = ClaudeBrandAssets.sourceImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
                    .foregroundStyle(.primary)
            } else {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum ClaudeBrandAssets {
    static let sourceImage = MonochromeBrandImage.sourceImage(
        named: "ClaudeMonochromePNG"
    )
}
