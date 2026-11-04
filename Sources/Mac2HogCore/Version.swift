import Foundation

/// Mac2Hog follows Semantic Versioning (https://semver.org). Bump on every commit:
/// PATCH for fixes and small changes, MINOR for new features, MAJOR for breaking changes.
/// Keep in sync with the `VERSION` file (checked by `VersionTests`); `scripts/build-app.sh`
/// writes it into the app's Info.plist.
public enum Mac2HogVersion {
    public static let current = "0.1.5"

    /// The running app's version: the bundle's Info.plist when packaged, otherwise `current`.
    public static var display: String {
        let bundle = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return bundle ?? current
    }

    public static var build: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
}
