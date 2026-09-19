import AppKit
import SwiftUI
import Testing
import SwitcherooCore
@testable import Switcheroo

@Suite(.serialized) @MainActor
struct AppTests {
    private func targets() -> [BrowserTarget] {
        let brave = BrowserInstallation(family: .brave, applicationURL: URL(fileURLWithPath: "/Applications/Brave Browser.app"),
            dataDirectory: URL(fileURLWithPath: "/tmp/SwitcherooTests"))
        let chrome = BrowserInstallation(family: .chrome, applicationURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"),
            dataDirectory: URL(fileURLWithPath: "/tmp/SwitcherooTestsChrome"))
        let safari = BrowserInstallation(family: .safari, applicationURL: URL(fileURLWithPath: "/Applications/Safari.app"))
        return [BrowserTarget(installation: brave, profileDirectory: "Default", name: "Personal"),
                BrowserTarget(installation: brave, profileDirectory: "Profile 1", name: "Work"),
                BrowserTarget(installation: chrome, profileDirectory: "Profile 2", name: "Work"),
                BrowserTarget(installation: safari, name: "Safari")]
    }

    @Test func settingsPersistIdentityOrderVisibilityAndReplacementRules() throws {
        let domain = "local.switcheroo.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let choices = targets()
        let model = AppModel(defaults: defaults)
        model.apply(CatalogSnapshot(targets: choices))
        model.move(choices[1], by: -1)
        model.setVisible(choices[0], false)
        model.saveRule(WebsiteRule(host: "example.com", targetID: choices[0].id))
        model.saveRule(WebsiteRule(host: "example.com", targetID: choices[1].id))
        model.finishSetup()
        let reloaded = AppModel(defaults: defaults)
        reloaded.apply(CatalogSnapshot(targets: choices))
        #expect(reloaded.visibleTargets.map(\.id) == [choices[1].id, choices[2].id, choices[3].id])
        #expect(reloaded.preferences.rules.count == 1)
        #expect(reloaded.preferences.rules.first?.targetID == choices[1].id)
        #expect(reloaded.preferences.hasCompletedSetup)
    }

    @Test func corruptSettingsAreNotOverwritten() throws {
        let domain = "local.switcheroo.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let badData = Data("broken".utf8)
        defaults.set(badData, forKey: "settings.v1")
        let model = AppModel(defaults: defaults)
        model.finishSetup()
        #expect(model.notice != nil)
        #expect(defaults.data(forKey: "settings.v1") == badData)
    }

    @Test func catalogReadsOnlyExistingProfilesFromATemporaryRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Profile 9"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"profile":{"info_cache":{"Profile 9":{"name":"Actual Work Name"},"Deleted":{"name":"Gone"}}}}"#.utf8)
            .write(to: root.appendingPathComponent("Local State"))
        let browser = BrowserInstallation(family: .edge, applicationURL: URL(fileURLWithPath: "/Applications/Microsoft Edge.app"), dataDirectory: root)
        let catalog = BrowserCatalog.read([browser])
        #expect(catalog.issues.isEmpty)
        #expect(catalog.targets.map(\.name) == ["Actual Work Name"])
        #expect(catalog.targets.first?.profileDirectory == "Profile 9")
        try FileManager.default.removeItem(at: root.appendingPathComponent("Local State"))
        let missing = BrowserCatalog.read([browser])
        #expect(missing.targets.isEmpty)
        #expect(missing.issues.count == 1)
        #expect(missing.issues.first?.reason == .notReady)
        #expect(missing.issues.first?.actionTitle == "Open Edge")
        try Data("broken".utf8).write(to: root.appendingPathComponent("Local State"))
        #expect(BrowserCatalog.read([browser]).issues.first?.reason == .unreadable)
        try Data(#"{"profile":{"info_cache":{}}}"#.utf8).write(to: root.appendingPathComponent("Local State"))
        #expect(BrowserCatalog.read([browser]).issues.first?.reason == .notReady)
    }

    @Test func profileAccessOffersTheRightNextStep() {
        let denied = CocoaError(.fileReadNoPermission)
        #expect(BrowserCatalog.accessReason(for: denied) == .needsPermission)
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        #expect(BrowserCatalog.accessReason(for: posix) == .needsPermission)
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadUnknown.rawValue,
                              userInfo: [NSUnderlyingErrorKey: posix])
        #expect(BrowserCatalog.accessReason(for: wrapped) == .needsPermission)
        let issue = BrowserAccessIssue(installation: targets()[0].installation, reason: .needsPermission)
        #expect(issue.actionTitle == "Connect Brave")
        #expect(BrowserCatalog.accessReason(for: CocoaError(.fileReadNoSuchFile)) == .notReady)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHEROO_CAPTURE_DIR"] != nil))
    func nativePickerKeyboardAndVisualChecks() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHEROO_CAPTURE_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let domain = "local.switcheroo.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var opened: [String] = []
        let model = AppModel(defaults: defaults) { target, _ in opened.append(target.id) }
        let choices = targets()
        model.apply(CatalogSnapshot(targets: choices))
        let controller = PickerController(model: model)
        model.router.stateDidChange = { controller.sync() }
        let url = URL(string: "https://github.com/your-org/project?tab=issues#latest")!
        model.router.enqueue([url])
        let window = try #require(app.windows.first { $0.title == "Switcheroo" && $0.isVisible })
        defer { window.close() }
        try await capture(window, name: "picker-light", appearance: .aqua, directory: directory)
        try await capture(window, name: "picker-dark", appearance: .darkAqua, directory: directory)
        let threeProfiles = [
            choices[0],
            BrowserTarget(installation: choices[0].installation, profileDirectory: "Profile 1", name: "work@example.com"),
            BrowserTarget(installation: choices[0].installation, profileDirectory: "Profile 2", name: "Service account")
        ]
        for count in 1...3 {
            model.apply(CatalogSnapshot(targets: Array(threeProfiles.prefix(count))))
            try await capture(window, name: "picker-centered-\(count)", appearance: .aqua, directory: directory)
        }
        model.apply(CatalogSnapshot(targets: threeProfiles, issues: [
            BrowserAccessIssue(installation: choices[2].installation, reason: .needsPermission)
        ]))
        try await capture(window, name: "picker-centered-3-dark", appearance: .darkAqua, directory: directory)
        model.apply(CatalogSnapshot(targets: choices))
        // Browser activation is not an outside click and must not discard a queued link.
        window.resignKey()
        #expect(model.router.current?.url == url)
        window.makeKeyAndOrderFront(nil)
        let extra = (3...14).map { BrowserTarget(installation: choices[0].installation,
            profileDirectory: "Profile \($0)", name: "A very long work profile name \($0)") }
        model.apply(CatalogSnapshot(targets: choices + extra))
        try await capture(window, name: "picker-overflow", appearance: .aqua, directory: directory)
        model.apply(CatalogSnapshot(targets: choices))
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "2",
            charactersIgnoringModifiers: "2", isARepeat: false, keyCode: 19))
        window.sendEvent(key)
        for _ in 0..<100 where model.router.isLaunching { await Task.yield() }
        #expect(opened == [choices[1].id])
        #expect(model.router.current == nil)

        var warmTimes: [Double] = []
        for _ in 0..<5 {
            let start = ContinuousClock.now
            model.router.enqueue([url])
            window.displayIfNeeded()
            let duration = start.duration(to: .now)
            warmTimes.append(Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15)
            model.router.cancel()
        }
        try JSONSerialization.data(withJSONObject: ["warmPickerMilliseconds": warmTimes], options: [.prettyPrinted])
            .write(to: directory.appendingPathComponent("metrics.json"))

        let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model, close: {})))
        settings.title = "Switcheroo Test Settings"
        settings.setContentSize(NSSize(width: 640, height: 570))
        settings.orderFrontRegardless()
        defer { settings.close() }
        try await capture(settings, name: "setup-ready", appearance: .aqua, directory: directory)
        try await capture(settings, name: "setup-ready-dark", appearance: .darkAqua, directory: directory)
        model.apply(CatalogSnapshot(targets: [choices[3]], issues: [
            BrowserAccessIssue(installation: choices[0].installation, reason: .needsPermission),
            BrowserAccessIssue(installation: choices[2].installation, reason: .notReady)
        ]))
        try await capture(settings, name: "setup-connect", appearance: .aqua, directory: directory)
        model.apply(CatalogSnapshot(targets: choices))
        model.finishSetup()
        model.saveRule(WebsiteRule(host: "github.com", targetID: choices[1].id))
        for tab in AppModel.SettingsTab.allCases {
            model.selectedTab = tab
            try await capture(settings, name: "settings-\(tab.rawValue)", appearance: .aqua, directory: directory)
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHEROO_CAPTURE_DIR"] != nil))
    func profileFolderIsPreselectedForApprovalAndCanBeCancelled() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let captures = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SWITCHEROO_CAPTURE_DIR"]!)
        let root = captures.appendingPathComponent("SwitcherooProfileAccess-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Default"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let prompt = ProfileAccessPanel(browserName: "Brave", directory: root)
        #expect(!prompt.panel(prompt.panel, shouldEnable: root.appendingPathComponent("Default")))
        #expect(throws: LaunchFailure.self) { try prompt.panel(prompt.panel, validate: root.deletingLastPathComponent()) }
        var selected: URL?
        var completed = false
        prompt.begin { selected = $0; completed = true }
        defer { prompt.panel.cancel(nil) }
        app.activate()
        prompt.panel.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(500))
        #expect(prompt.panel.directoryURL?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        // Check the dialog's actual selection, not just its configured directoryURL.
        // File-picker UI lives in a separate macOS process and doesn't accept synthetic NSEvents.
        #expect(prompt.panel.urls.count == 1)
        let readyForApproval = try #require(prompt.panel.urls.first)
        #expect(readyForApproval.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path)
        try prompt.panel(prompt.panel, validate: readyForApproval)
        prompt.panel.cancel(nil)
        for _ in 0..<50 where !completed { try await Task.sleep(for: .milliseconds(20)) }
        #expect(completed)
        #expect(selected == nil)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHEROO_SAFARI_SMOKE_URL"] != nil))
    func safariReceivesExplicitLaunch() async throws {
        _ = NSApplication.shared
        let appURL = try #require(NSWorkspace.shared.urlForApplication(withBundleIdentifier: BrowserFamily.safari.bundleIdentifier))
        let installation = BrowserInstallation(family: .safari, applicationURL: appURL)
        let url = try #require(URL(string: ProcessInfo.processInfo.environment["SWITCHEROO_SAFARI_SMOKE_URL"]!))
        try await BrowserLauncher.open(BrowserTarget(installation: installation, name: "Safari"), url: url)
    }

    private func capture(_ window: NSWindow, name: String, appearance: NSAppearance.Name, directory: URL) async throws {
        window.appearance = NSAppearance(named: appearance)
        try await Task.sleep(for: .milliseconds(150))
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent(name + ".png"))
    }
}
