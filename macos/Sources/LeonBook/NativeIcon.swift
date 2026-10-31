import AppKit
import SwiftUI

/// All app chrome uses regular, monochrome outline symbols on a square canvas.
/// Keep stored symbol names intact; normalize only when rendering the interface.
enum NativeIcon {
    enum Size {
        static let metadata: CGFloat = 12
        static let small: CGFloat = 14
        static let standard: CGFloat = 16
        static let toolbar: CGFloat = 18
        static let emptyState: CGFloat = 32
    }

    private static let images: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 512
        return cache
    }()

    private static let aliases = [
        "doc": "doc.text",
        "text.document": "doc.text",
        "doc.richtext": "doc.text",
        "photo.on.rectangle.angled": "photo.on.rectangle",
        "photo.stack": "photo.on.rectangle",
        "square.grid.3x1.folder.badge.plus": "rectangle.split.3x1",
    ]

    static func outlineName(_ name: String) -> String {
        let outline = name.split(separator: ".").filter { $0 != "fill" }.joined(separator: ".")
        return aliases[outline] ?? outline
    }

    static func image(_ name: String, size: CGFloat = Size.standard) -> Image {
        Image(nsImage: nsImage(name, size: size)).renderingMode(.template)
    }

    static func nsImage(_ name: String, size: CGFloat = Size.standard) -> NSImage {
        let size = min(max(size, 8), 96) * 1.10
        let outline = outlineName(name)
        let key = "\(outline):\(size)" as NSString
        if let cached = images.object(forKey: key) { return cached }

        let symbol = NSImage(systemSymbolName: outline, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: name, accessibilityDescription: nil)
            ?? NSImage(systemSymbolName: "questionmark", accessibilityDescription: nil)!
        let configured = symbol.withSymbolConfiguration(.init(pointSize: size, weight: .regular)) ?? symbol
        let logicalSize = NSSize(width: size, height: size)
        let draw: (NSRect) -> Bool = { rect in
            let factor = min(rect.width / configured.size.width, rect.height / configured.size.height)
            let fitted = NSSize(width: configured.size.width * factor, height: configured.size.height * factor)
            configured.draw(in: NSRect(
                x: rect.midX - fitted.width / 2, y: rect.midY - fitted.height / 2,
                width: fitted.width, height: fitted.height
            ))
            return true
        }
        // A drawing-handler image rerenders the symbol's vector parts when
        // SwiftUI rebuilds a scrolling display list. Cache the finished mask.
        let image: NSImage
        let scale: CGFloat = 2
        if let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(ceil(size * scale)), pixelsHigh: Int(ceil(size * scale)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            context.cgContext.scaleBy(x: scale, y: scale)
            _ = draw(NSRect(origin: .zero, size: logicalSize))
            NSGraphicsContext.restoreGraphicsState()
            bitmap.size = logicalSize
            image = NSImage(size: logicalSize)
            image.addRepresentation(bitmap)
        } else {
            image = NSImage(size: logicalSize, flipped: false, drawingHandler: draw)
        }
        image.isTemplate = true
        image.accessibilityDescription = symbol.accessibilityDescription
        images.setObject(image, forKey: key)
        return image
    }
}

extension Label where Title == Text, Icon == Image {
    init(_ title: LocalizedStringKey, nativeIcon: String, iconSize: CGFloat = NativeIcon.Size.standard) {
        self.init { Text(title) } icon: { NativeIcon.image(nativeIcon, size: iconSize) }
    }

    init<S: StringProtocol>(_ title: S, nativeIcon: String, iconSize: CGFloat = NativeIcon.Size.standard) {
        self.init { Text(title) } icon: { NativeIcon.image(nativeIcon, size: iconSize) }
    }
}

extension Button where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, nativeIcon: String, iconSize: CGFloat = NativeIcon.Size.standard,
         role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            SwiftUI.Label(title, nativeIcon: nativeIcon, iconSize: iconSize)
        }
    }

    init<S: StringProtocol>(_ title: S, nativeIcon: String, iconSize: CGFloat = NativeIcon.Size.standard,
                            role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.init(role: role, action: action) {
            SwiftUI.Label(title, nativeIcon: nativeIcon, iconSize: iconSize)
        }
    }
}

extension Menu where Label == SwiftUI.Label<Text, Image> {
    init(_ title: LocalizedStringKey, nativeIcon: String, iconSize: CGFloat = NativeIcon.Size.standard,
         @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, nativeIcon: nativeIcon, iconSize: iconSize) }
    }

    init<S: StringProtocol>(_ title: S, nativeIcon: String, iconSize: CGFloat = NativeIcon.Size.standard,
                            @ViewBuilder content: () -> Content) {
        self.init(content: content) { SwiftUI.Label(title, nativeIcon: nativeIcon, iconSize: iconSize) }
    }
}
