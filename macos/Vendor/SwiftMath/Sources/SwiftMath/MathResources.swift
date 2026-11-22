import Foundation

/// A signed macOS app keeps resources under Contents/Resources, not its bundle root.
enum MathResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.url(forResource: "SwiftMath_SwiftMath", withExtension: "bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
