import Foundation

public enum ApplicationTargetMatching {
    public static func matches(
        target: String,
        bundleIdentifier: String,
        displayNames: [String] = []
    ) -> Bool {
        if bundleIdentifier.caseInsensitiveCompare(target) == .orderedSame {
            return true
        }
        if displayNames.contains(where: {
            $0.caseInsensitiveCompare(target) == .orderedSame
        }) {
            return true
        }

        let normalizedTarget = normalizedAlias(target)
        guard !normalizedTarget.isEmpty,
              let bundleName = bundleIdentifier.split(separator: ".").last
        else { return false }
        return normalizedAlias(String(bundleName)) == normalizedTarget
    }

    private static func normalizedAlias(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        })
    }
}
