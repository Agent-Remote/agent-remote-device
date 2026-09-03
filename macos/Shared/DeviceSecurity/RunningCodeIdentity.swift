import Darwin
import Foundation
import Security

public enum RunningCodeIdentity {
    public static func signingIdentifier(bundleURL: URL) -> String? {
        guard bundleURL.isFileURL, bundleURL.pathExtension.lowercased() == "app" else {
            return nil
        }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                  staticCode,
                  SecCSFlags(rawValue: kSecCSStrictValidate),
                  nil
              ) == errSecSuccess
        else {
            return nil
        }
        return signingIdentifier(staticCode: staticCode)
    }

    public static func signingIdentifier(processID: pid_t) -> String? {
        guard processID > 0 else { return nil }
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: processID),
        ] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(
            nil,
            attributes,
            SecCSFlags(),
            &code
        ) == errSecSuccess,
            let code,
            SecCodeCheckValidity(
                code,
                SecCSFlags(rawValue: kSecCSStrictValidate),
                nil
            ) == errSecSuccess
        else {
            return nil
        }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else {
            return nil
        }
        return signingIdentifier(staticCode: staticCode)
    }

    private static func signingIdentifier(staticCode: SecStaticCode) -> String? {
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
            let values = information as? [String: Any]
        else {
            return nil
        }
        return values[kSecCodeInfoIdentifier as String] as? String
    }
}
