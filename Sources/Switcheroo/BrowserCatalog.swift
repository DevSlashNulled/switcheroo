import AppKit
import SwitcherooCore

struct BrowserAccessIssue: Identifiable, Sendable {
    let installation: BrowserInstallation
    let reason: Reason
    var id: String { installation.id }

    enum Reason: Equatable, Sendable {
        case needsPermission, notReady, unreadable
    }

    var message: String {
        switch reason {
        case .needsPermission:
            "Allow Switcheroo to see your profile names. The correct folder opens for you."
        case .notReady:
            "Open \(installation.family.name) and finish its setup. Your profiles will appear when you return."
        case .unreadable:
            "Your profiles couldn’t be read. Open \(installation.family.name), then return here to try again."
        }
    }

    var actionTitle: String {
        "\(reason == .needsPermission ? "Connect" : "Open") \(installation.family.name)"
    }
}

struct CatalogSnapshot: Sendable {
    var targets: [BrowserTarget] = []
    var issues: [BrowserAccessIssue] = []
}

@MainActor
enum BrowserCatalog {
    static func defaultDataDirectory(for family: BrowserFamily) -> URL? {
        family.dataSubdirectory.map {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support").appendingPathComponent($0, isDirectory: true)
        }
    }

    static func installations(bookmarks: [String: Data]) -> [BrowserInstallation] {
        BrowserFamily.allCases.compactMap { family in
            guard let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: family.bundleIdentifier
            ) else { return nil }
            var root = defaultDataDirectory(for: family)
            if let data = bookmarks[family.bundleIdentifier] {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: data,
                                          options: [.withoutUI, .withSecurityScope],
                                          bookmarkDataIsStale: &stale),
                   resolved.resolvingSymlinksInPath().path == root?.resolvingSymlinksInPath().path {
                    root = resolved
                }
            }
            return BrowserInstallation(family: family, applicationURL: applicationURL, dataDirectory: root)
        }
    }

    nonisolated static func read(_ installations: [BrowserInstallation]) -> CatalogSnapshot {
        var snapshot = CatalogSnapshot()
        for installation in installations {
            guard let root = installation.dataDirectory else {
                snapshot.targets.append(BrowserTarget(installation: installation, name: installation.family.name))
                continue
            }
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: root.appendingPathComponent("Local State"))
                let directories = try FileManager.default.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
                ).filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                let profiles = try ProfileParser.parse(data, installation: installation,
                                                      existingDirectories: Set(directories.map(\.lastPathComponent)))
                snapshot.targets += profiles
                if profiles.isEmpty {
                    snapshot.issues.append(BrowserAccessIssue(installation: installation, reason: .notReady))
                }
            } catch {
                snapshot.issues.append(BrowserAccessIssue(installation: installation, reason: accessReason(for: error)))
            }
        }
        return snapshot
    }

    nonisolated static func accessReason(for error: Error) -> BrowserAccessIssue.Reason {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain {
            if error.code == CocoaError.fileReadNoPermission.rawValue { return .needsPermission }
            if [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains(error.code) {
                return .notReady
            }
        }
        if error.domain == NSPOSIXErrorDomain {
            if [Int(EACCES), Int(EPERM)].contains(error.code) { return .needsPermission }
            if error.code == Int(ENOENT) { return .notReady }
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? Error {
            return accessReason(for: underlying)
        }
        return .unreadable
    }
}
