import AppKit
import SwiftUI

struct CodexGlyphView: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let image = CodexBrandAssets.monochromeImage {
                Image(nsImage: image)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum CodexBrandAssets {
    static let monochromeImage = MonochromeBrandImage.image(
        named: "CodexMonochromePNG"
    )
}

enum MonochromeBrandImage {
    static let size = NSSize(width: 16, height: 16)

    static func image(named resourceName: String) -> NSImage? {
        make(from: sourceImage(named: resourceName))
    }

    static func sourceImage(named resourceName: String) -> NSImage? {
        guard
            let url = Bundle.main.url(
                forResource: resourceName,
                withExtension: "base64"
            ),
            let encoded = try? String(contentsOf: url, encoding: .utf8),
            let data = Data(
                base64Encoded: encoded,
                options: .ignoreUnknownCharacters
            ),
            let source = NSImage(data: data)
        else {
            return nil
        }

        return source
    }

    static func make(from source: NSImage?) -> NSImage? {
        guard let source else { return nil }
        guard let image = source.copy() as? NSImage else { return nil }

        image.size = size
        image.isTemplate = true
        return image
    }
}
