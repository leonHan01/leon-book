import Foundation
import SwiftUI

private let nativeLanguageDefaultsKey = "leon-book.app-language.v1"

public enum NativeAppLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    public var id: String { rawValue }

    public var locale: Locale {
        Locale(identifier: rawValue)
    }

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    static func preferred(from identifiers: [String]) -> Self {
        guard let identifier = identifiers.first?.lowercased() else {
            return .simplifiedChinese
        }
        return identifier.hasPrefix("en") ? .english : .simplifiedChinese
    }
}

@MainActor
public final class NativeLanguagePreferences: ObservableObject {
    public static let shared = NativeLanguagePreferences()

    @Published public var language: NativeAppLanguage {
        didSet {
            defaults.set(language.rawValue, forKey: defaultsKey)
        }
    }

    private let defaults: UserDefaults
    private let defaultsKey: String

    public init(
        defaults: UserDefaults = .standard,
        defaultsKey: String = "leon-book.app-language.v1",
        preferredLanguages: [String] = Locale.preferredLanguages
    ) {
        self.defaults = defaults
        self.defaultsKey = defaultsKey
        language = defaults.string(forKey: defaultsKey)
            .flatMap(NativeAppLanguage.init(rawValue:))
            ?? NativeAppLanguage.preferred(from: preferredLanguages)
    }
}

public enum NativeLocalization {
    public static var currentLanguage: NativeAppLanguage {
        UserDefaults.standard.string(forKey: nativeLanguageDefaultsKey)
            .flatMap(NativeAppLanguage.init(rawValue:))
            ?? NativeAppLanguage.preferred(from: Locale.preferredLanguages)
    }

    public static func string(
        _ key: String,
        language: NativeAppLanguage,
        table: String? = nil
    ) -> String {
        for baseBundle in [Bundle.module, Bundle.main] {
            guard let path = baseBundle.path(forResource: language.rawValue, ofType: "lproj"),
                  let languageBundle = Bundle(path: path) else { continue }
            let localized = languageBundle.localizedString(forKey: key, value: nil, table: table)
            if localized != key || language == .simplifiedChinese {
                return localized
            }
        }
        return key
    }
}
