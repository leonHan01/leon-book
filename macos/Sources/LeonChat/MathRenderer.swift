import AppKit
import SwiftMath

enum MathRenderer {
    struct Rendered {
        let image: NSImage
        let descent: CGFloat

        func fitting(width: CGFloat) -> Rendered {
            guard image.size.width > width, width > 0 else { return self }
            let scale = width / image.size.width
            let size = NSSize(width: width, height: image.size.height * scale)
            let original = image
            let scaled = NSImage(size: size, flipped: false) { bounds in
                original.draw(in: bounds)
                return true
            }
            return Rendered(image: scaled, descent: descent * scale)
        }
    }

    private final class Entry {
        let value: Rendered?
        init(_ value: Rendered?) { self.value = value }
    }
    private static let cache: NSCache<NSString, Entry> = {
        let cache = NSCache<NSString, Entry>()
        cache.countLimit = 256
        return cache
    }()

    static func render(_ expression: MathMarkup.Expression, size: CGFloat = 16, white: Bool) -> Rendered? {
        guard expression.complete else { return nil }
        let key = "\(size)|\(white)|\(expression.display)|\(expression.latex)" as NSString
        if let cached = cache.object(forKey: key) { return cached.value }
        var math = MathImage(latex: expression.latex, fontSize: size,
                             textColor: white ? .white : .black,
                             labelMode: expression.display ? .display : .text,
                             textAlignment: .left)
        let (error, image, layout) = math.asImage()
        let rendered: Rendered?
        if error == nil, let image, let layout, image.size.width > 0, image.size.height > 0 {
            rendered = Rendered(image: image, descent: layout.descent)
        } else {
            rendered = nil
        }
        cache.setObject(Entry(rendered), forKey: key)
        return rendered
    }
}
