import Foundation

public enum BrowserFamily: String, CaseIterable, Codable, Sendable {
    case brave, chrome, edge, safari, firefox

    public var name: String {
        switch self {
        case .brave: "Brave"
        case .chrome: "Chrome"
        case .edge: "Edge"
        case .safari: "Safari"
        case .firefox: "Firefox"
        }
    }

    public var bundleIdentifier: String {
        switch self {
        case .brave: "com.brave.Browser"
        case .chrome: "com.google.Chrome"
        case .edge: "com.microsoft.edgemac"
        case .safari: "com.apple.Safari"
        case .firefox: "org.mozilla.firefox"
        }
    }

    public var dataSubdirectory: String? {
        switch self {
        case .brave: "BraveSoftware/Brave-Browser"
        case .chrome: "Google/Chrome"
        case .edge: "Microsoft Edge"
        case .safari, .firefox: nil
        }
    }
}

public struct BrowserInstallation: Identifiable, Hashable, Sendable {
    public let family: BrowserFamily
    public let applicationURL: URL
    public let dataDirectory: URL?
    public var id: String { family.bundleIdentifier }

    public init(family: BrowserFamily, applicationURL: URL, dataDirectory: URL? = nil) {
        self.family = family
        self.applicationURL = applicationURL
        self.dataDirectory = dataDirectory
    }
}

public struct BrowserTarget: Identifiable, Hashable, Sendable {
    public let installation: BrowserInstallation
    public let profileDirectory: String?
    public let name: String
    public var id: String { installation.id + ":" + (profileDirectory ?? "") }
    public var browserName: String { installation.family.name }
    public var initials: String {
        let words = name.split(whereSeparator: { $0.isWhitespace })
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }
    public var colorIndex: Int { id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff } % 6 }

    public init(installation: BrowserInstallation, profileDirectory: String? = nil, name: String) {
        self.installation = installation
        self.profileDirectory = profileDirectory
        self.name = name
    }

    public var chromiumArguments: [String]? {
        guard let profileDirectory, let root = installation.dataDirectory else { return nil }
        return ["-n", "-a", installation.applicationURL.path, "--args",
                "--user-data-dir=" + root.path, "--profile-directory=" + profileDirectory]
    }

    public func launchArguments(for url: URL) -> [String]? {
        chromiumArguments.map { $0 + ["--", url.absoluteString] }
    }
}

public enum ProfileParser {
    private struct State: Decodable {
        struct Profile: Decodable {
            struct Entry: Decodable {
                let name: String?
                let is_omitted: Bool?
            }
            let info_cache: [String: Entry]
        }
        let profile: Profile
    }

    public static func isValidDirectory(_ directory: String) -> Bool {
        !directory.isEmpty && directory != "." && directory != ".."
            && !directory.contains("/") && !directory.contains("\\")
            && !directory.contains("\0")
            && directory != "Guest Profile" && directory != "System Profile"
    }

    public static func parse(_ data: Data, installation: BrowserInstallation,
                             existingDirectories: Set<String>) throws -> [BrowserTarget] {
        let state = try JSONDecoder().decode(State.self, from: data)
        return state.profile.info_cache.compactMap { directory, entry in
            guard isValidDirectory(directory), existingDirectories.contains(directory),
                  entry.is_omitted != true else { return nil }
            let name = entry.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BrowserTarget(installation: installation, profileDirectory: directory,
                                 name: name.isEmpty ? directory : name)
        }.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}

public struct PendingLink: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let url: URL
    public var host: String { Self.host(for: url)! }

    public init?(url: URL, id: UUID = UUID()) {
        guard Self.host(for: url) != nil else { return nil }
        self.id = id
        self.url = url
    }

    public static func host(for url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              var host = url.host?.lowercased(), !host.isEmpty else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }

    public static func host(fromInput input: String) -> String? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty, !input.contains(where: { $0.isWhitespace }),
              !input.contains("*"), !input.contains("@"),
              let url = URL(string: input.contains("://") ? input : "https://" + input),
              url.user == nil, url.password == nil else { return nil }
        return host(for: url)
    }
}

public struct WebsiteRule: Identifiable, Codable, Equatable, Sendable {
    public var host: String
    public var targetID: String
    public var isEnabled: Bool
    public var id: String { host }

    public init(host: String, targetID: String, isEnabled: Bool = true) {
        self.host = host
        self.targetID = targetID
        self.isEnabled = isEnabled
    }
}

public struct Preferences: Codable, Equatable, Sendable {
    public var version = 1
    public var hasCompletedSetup = false
    public var orderedTargetIDs: [String] = []
    public var hiddenTargetIDs: Set<String> = []
    public var folderBookmarks: [String: Data] = [:]
    public var rules: [WebsiteRule] = []
    public init() {}

    public func ordered(_ targets: [BrowserTarget]) -> [BrowserTarget] {
        let ranks = Dictionary(orderedTargetIDs.enumerated().map { ($1, $0) },
                               uniquingKeysWith: { first, _ in first })
        return targets.enumerated().sorted {
            let left = ranks[$0.element.id] ?? Int.max
            let right = ranks[$1.element.id] ?? Int.max
            return left == right ? $0.offset < $1.offset : left < right
        }.map(\.element)
    }
}
