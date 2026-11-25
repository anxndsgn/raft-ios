import Foundation

/// UI strings. Keys are the old app's (`compose/shared/.../values/strings.xml`), so its zh-Hans
/// translations carry over; strings the old app did not have use `ios_` keys and pass their English
/// as `fallback` until translations land. `Localizable.xcstrings` is generated from these calls by
/// `scripts/gen-strings.py`.
enum L10n {
    static func t(_ key: String, _ fallback: String? = nil) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: fallback ?? key, comment: "")
    }

    /// "XIN (you)"; the zh-Hans suffix ("（你）") brings its own full-width spacing.
    static func withYouSuffix(_ name: String) -> String {
        let suffix = L10n.t("member_label_you_suffix", "(you)")
        let ascii = suffix.unicodeScalars.first?.isASCII ?? true
        return name + (ascii ? " " : "") + suffix
    }

    /// A format string (`%1$@`, `%1$d`) filled with `args`.
    static func f(_ key: String, _ fallback: String? = nil, _ args: CVarArg...) -> String {
        String(format: t(key, fallback), locale: .current, arguments: args)
    }
}
