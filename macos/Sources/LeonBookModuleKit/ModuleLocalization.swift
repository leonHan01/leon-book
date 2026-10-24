import Foundation

/// A message keeps substitutions separate from its translation key. User text
/// is inserted after translation and is never treated as a localization key.
public struct ModuleLocalizedMessage: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
    public let key: String
    public let arguments: [String]

    public init(stringLiteral value: String) {
        key = value
        arguments = []
    }

    public init(stringInterpolation: StringInterpolation) {
        key = stringInterpolation.key
        arguments = stringInterpolation.arguments
    }

    public struct StringInterpolation: StringInterpolationProtocol {
        var key = ""
        var arguments: [String] = []

        public init(literalCapacity: Int, interpolationCount: Int) {
            key.reserveCapacity(literalCapacity)
            arguments.reserveCapacity(interpolationCount)
        }

        public mutating func appendLiteral(_ literal: String) {
            key += literal.replacingOccurrences(of: "%", with: "%%")
        }

        public mutating func appendInterpolation<Value>(_ value: Value) {
            key += "%@"
            arguments.append(String(describing: value))
        }
    }
}

/// Foundation-only localization shared by modules that cannot depend on the UI.
public enum ModuleLocalization {
    public static var languageIdentifier: String {
        if let saved = UserDefaults.standard.string(forKey: "leon-book.app-language.v1"),
           ["en", "zh-Hans"].contains(saved) { return saved }
        return Locale.preferredLanguages.first?.lowercased().hasPrefix("en") == true ? "en" : "zh-Hans"
    }

    public static func string(
        _ key: String,
        language: String = languageIdentifier,
        bundle: Bundle? = nil,
        table: String? = nil
    ) -> String {
        for base in bundles(preferred: bundle) {
            guard let path = base.path(forResource: language, ofType: "lproj"),
                  let localizedBundle = Bundle(path: path) else { continue }
            let value = localizedBundle.localizedString(forKey: key, value: nil, table: table)
            if value != key { return value }
        }
        return key
    }

    public static func text(
        _ message: ModuleLocalizedMessage,
        language: String = languageIdentifier,
        bundle: Bundle? = nil
    ) -> String {
        let format = string(message.key, language: language, bundle: bundle)
        guard !message.arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: language), arguments: message.arguments)
    }

    private static func bundles(preferred: Bundle?) -> [Bundle] {
        let name = "LeonBookMac_LeonBook.bundle"
        let urls = [
            Bundle.main.resourceURL?.appendingPathComponent(name),
            Bundle.main.bundleURL.appendingPathComponent(name),
        ]
        return [preferred].compactMap { $0 } + urls.compactMap { $0 }.compactMap(Bundle.init(url:)) + [Bundle.main]
    }
}
