import Foundation

enum DeviceSupportPolicy {
    static func isSupported(major: Int, minor: Int, patch: Int) -> Bool {
        major >= 16
    }
}

enum ExploitSupportPolicy {
    static let verifiedIOS16Range = "16.0+"
    static let verifiedIOS17Range = "17.0+"
    static let verifiedIOS18Range = "18.0+"
    static let verifiedIOS26Range = "26.0+"
    static let verifiedIOS27Builds: [(beta: Int, publicBeta: Int?, build: String)] = []

    static func iOS27BetaNumber(for build: String) -> Int? { nil }
    static func iOS27PublicBetaNumber(for build: String) -> Int? { nil }

    static func supportsKernelExploit(major: Int, minor: Int, patch: Int) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        if major == 17 {
            return minor <= 7
        }

        if major == 18 {
            return minor < 7 || (minor == 7 && patch <= 9)
        }

        return false
    }

    static func isSupported(major: Int, minor: Int, patch: Int, build: String) -> Bool {
        guard minor >= 0, patch >= 0 else { return false }

        switch major {
        case 16:
            // All released iOS 16 minor releases are supported.
            return minor <= 7

        case 17:
            // All released iOS 17 minor releases are supported.
            return minor <= 7

        case 18:
            // Supported through iOS 18.7.9. 18.7.10+ is unsupported.
            return minor < 7 || (minor == 7 && patch <= 9)

        case 26:
            // Supported through iOS 26.2. 26.2.1+ is unsupported.
            return minor < 2 || (minor == 2 && patch == 0)

        case 27:
            // All iOS 27 releases are unsupported.
            return false

        default:
            // iOS 15 and any other unlisted major version are unsupported.
            return false
        }
    }
}
