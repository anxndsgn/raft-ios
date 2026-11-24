import Foundation

/// Static facts about this build, read once from Info.plist.
struct AppInfo: Sendable, Hashable {
    let version: String
    let build: String
    /// `Debug` or `Release` (the Xcode configuration).
    let buildType: String
    let osVersion: String
    /// URL scheme of the browser sign-in callback (`raft-debug` in Debug, `raft` in Release).
    let callbackScheme: String

    static let current: AppInfo = {
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = os.patchVersion > 0
            ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
            : "\(os.majorVersion).\(os.minorVersion)"
        return AppInfo(
            version: (info["CFBundleShortVersionString"] as? String) ?? "0",
            build: (info["CFBundleVersion"] as? String) ?? "0",
            buildType: (info["RaftBuildType"] as? String) ?? "Debug",
            osVersion: osVersion,
            callbackScheme: (info["RaftOAuthCallbackScheme"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "raft-debug"
        )
    }()

    /// `Raft/<version>+<build> (iOS <os>; <buildType>) iPhone`: the old app's format. The server
    /// derives the device type from the `iPhone` token and the version from `Raft/<version>`.
    var userAgent: String {
        "Raft/\(version)+\(build) (iOS \(osVersion); \(buildType.lowercased())) iPhone"
    }

    /// `raft-debug://login/callback` (Debug) or `raft://login/callback` (Release).
    var loginCallbackURI: String { "\(callbackScheme)://login/callback" }
}
