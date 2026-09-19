import AppKit
import Observation
import ServiceManagement
import SwitcherooCore

@MainActor @Observable
final class AppModel {
    let router: LinkRouter
    private(set) var preferences = Preferences()
    private(set) var allTargets: [BrowserTarget] = []
    private(set) var accessIssues: [BrowserAccessIssue] = []
    private(set) var isRefreshing = false
    private(set) var isDefaultBrowser = false
    private(set) var isRequestingDefaultBrowser = false
    private(set) var loginStatus = SMAppService.mainApp.status
    var notice: String?
    var selectedTab = SettingsTab.general
    @ObservationIgnored var showSettings: (() -> Void)?
    @ObservationIgnored var menuDidChange: (() -> Void)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var maySave = true
    @ObservationIgnored private var icons: [String: NSImage] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    private static let preferencesKey = "settings.v1"

    enum SettingsTab: String, CaseIterable {
        case general = "General", choices = "Choices", rules = "Website Rules"
    }

    init(defaults: UserDefaults = .standard,
         launch: @escaping (BrowserTarget, URL) async throws -> Void = BrowserLauncher.open) {
        self.defaults = defaults
        router = LinkRouter(launch: launch)
        if let data = defaults.data(forKey: Self.preferencesKey) {
            do {
                let decoded = try JSONDecoder().decode(Preferences.self, from: data)
                guard decoded.version == 1 else { throw LaunchFailure(message: "Unsupported settings version.") }
                preferences = decoded
            } catch {
                maySave = false
                notice = "Saved settings could not be read. They have been preserved. Quit and restore a compatible settings backup before making changes."
            }
        }
        router.rules = preferences.rules
        router.didRemember = { [weak self] rule in self?.saveRule(rule) }
        updateSystemStatus()
    }

    var visibleTargets: [BrowserTarget] {
        allTargets.filter { !preferences.hiddenTargetIDs.contains($0.id) }
    }

    func icon(for target: BrowserTarget) -> NSImage {
        let key = target.installation.applicationURL.path
        if let icon = icons[key] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: target.installation.applicationURL.path)
        icons[key] = icon
        return icon
    }

    func refresh() {
        guard refreshTask == nil else { refreshAgain = true; return }
        isRefreshing = true
        let installations = BrowserCatalog.installations(bookmarks: preferences.folderBookmarks)
        refreshTask = Task {
            let snapshot = await Task.detached(priority: .userInitiated) {
                BrowserCatalog.read(installations)
            }.value
            isRefreshing = false
            refreshTask = nil
            apply(snapshot)
            updateSystemStatus()
            if refreshAgain {
                refreshAgain = false
                refresh()
            }
        }
    }

    func apply(_ snapshot: CatalogSnapshot) {
        let known = Set(preferences.orderedTargetIDs)
        let newIDs = snapshot.targets.map(\.id).filter { !known.contains($0) }
        if !newIDs.isEmpty {
            preferences.orderedTargetIDs.append(contentsOf: newIDs)
            save()
        }
        allTargets = preferences.ordered(snapshot.targets)
        accessIssues = snapshot.issues
        for target in allTargets { _ = icon(for: target) }
        router.updateTargets(allTargets)
    }

    func receive(_ urls: [URL]) {
        // Queue immediately, even if discovery or another choice is still in progress.
        router.enqueue(urls)
        refresh()
    }

    func setVisible(_ target: BrowserTarget, _ visible: Bool) {
        if visible { preferences.hiddenTargetIDs.remove(target.id) }
        else { preferences.hiddenTargetIDs.insert(target.id) }
        save()
    }

    func move(_ target: BrowserTarget, by offset: Int) {
        guard let index = allTargets.firstIndex(where: { $0.id == target.id }),
              allTargets.indices.contains(index + offset) else { return }
        allTargets.swapAt(index, index + offset)
        preferences.orderedTargetIDs = allTargets.map(\.id)
        save()
    }

    func resolve(_ issue: BrowserAccessIssue) {
        guard issue.reason == .needsPermission else {
            let configuration = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: issue.installation.applicationURL, configuration: configuration) { [weak self] _, error in
                if let error {
                    Task { @MainActor in self?.notice = "Couldn’t open \(issue.installation.family.name). \(error.localizedDescription)" }
                }
            }
            return
        }
        grantAccess(issue)
    }

    private func grantAccess(_ issue: BrowserAccessIssue) {
        guard let directory = BrowserCatalog.defaultDataDirectory(for: issue.installation.family) else { return }
        let prompt = ProfileAccessPanel(browserName: issue.installation.family.name, directory: directory)
        prompt.begin { [weak self] url in
            guard let self, let url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                preferences.folderBookmarks[issue.id] = try url.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil, relativeTo: nil
                )
                save()
                refresh()
            } catch {
                notice = "Couldn’t connect \(issue.installation.family.name). Try Connect again, or check Switcheroo in System Settings → Privacy & Security → Files & Folders. \(error.localizedDescription)"
            }
        }
    }

    func saveRule(_ rule: WebsiteRule, replacing oldHost: String? = nil) {
        preferences.rules.removeAll { $0.host == rule.host || $0.host == oldHost }
        preferences.rules.append(rule)
        preferences.rules.sort { $0.host < $1.host }
        save()
    }

    func deleteRule(_ host: String) {
        preferences.rules.removeAll { $0.host == host }
        save()
    }

    func toggleRulesPaused() {
        router.rulesPaused.toggle()
        menuDidChange?()
    }

    func finishSetup() {
        preferences.hasCompletedSetup = true
        save()
    }

    func updateSystemStatus() {
        let workspace = NSWorkspace.shared
        let thisApp = Bundle.main.bundleURL.resolvingSymlinksInPath()
        isDefaultBrowser = ["http://example.com", "https://example.com"].allSatisfy {
            workspace.urlForApplication(toOpen: URL(string: $0)!)?.resolvingSymlinksInPath() == thisApp
        }
        loginStatus = SMAppService.mainApp.status
    }

    func makeDefaultBrowser(onSuccess: (() -> Void)? = nil) {
        guard !isRequestingDefaultBrowser else { return }
        isRequestingDefaultBrowser = true
        Task {
            defer { isRequestingDefaultBrowser = false }
            do {
                try await NSWorkspace.shared.setDefaultApplication(
                    at: Bundle.main.bundleURL, toOpenURLsWithScheme: "http"
                )
                updateSystemStatus()
                if !isDefaultBrowser {
                    notice = "Switcheroo is not yet the default for both HTTP and HTTPS. Select it in System Settings → Desktop & Dock → Default web browser."
                } else {
                    onSuccess?()
                }
            } catch { notice = error.localizedDescription }
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            updateSystemStatus()
            if loginStatus == .requiresApproval {
                notice = "Allow Switcheroo in System Settings → General → Login Items."
            }
        } catch { notice = error.localizedDescription }
    }

    private func save() {
        guard maySave else { return }
        do {
            defaults.set(try JSONEncoder().encode(preferences), forKey: Self.preferencesKey)
            router.rules = preferences.rules
        } catch { notice = "Couldn’t save settings. \(error.localizedDescription)" }
    }
}
