import Foundation

extension Bundle {
    /// Prefer resources installed in the app; SwiftPM's native accessor falls
    /// back to its temporary build directory when used inside a macOS bundle.
    static let leonBookResources: Bundle = {
        let name = "LeonBookMac_LeonBook.bundle"
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        if let installed = candidates.compactMap({ $0 }).compactMap(Bundle.init(url:)).first {
            return installed
        }
        return .module
    }()
}
