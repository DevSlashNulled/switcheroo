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

        model.router.cancel()
        model.apply(CatalogSnapshot(targets: threeProfiles))
        for (name, address) in [
            ("ticket", "https://hypixelstudios.zendesk.com/agent/tickets/90493"),
            ("deep-path", "https://example.com/projects/customer-support/documentation/équipe/日本語/agent/tickets/90493?filter=unassigned#activity"),
            ("long-host", "https://customer-support.internal-tools.regional-office.example.com/agent/tickets/90493"),
            ("long-query", "https://example.com/projects/customer-support/tickets/90493?view=all-open-tickets&sort=updated-descending&team=platform-engineering&filter=needs-review&source=weekly-report#latest-reply"),
            ("homepage", "https://example.com")
        ] {
            model.router.enqueue([try #require(URL(string: address))])
            try await capture(window, name: "picker-link-\(name)", appearance: .aqua, directory: directory)
            try await capture(window, name: "picker-link-\(name)-dark", appearance: .darkAqua, directory: directory)
            model.router.cancel()
        }
        let compactHeight = window.frame.height
        let longURL = try #require(URL(string: "https://example.com/" + String(repeating: "a", count: 2048) + "?query=complete#end"))
        let nextLongURL = try #require(URL(string: "https://example.org/" + String(repeating: "b", count: 2048) + "?query=next#end"))
        model.router.enqueue([longURL, nextLongURL, url])
        try await capture(window, name: "picker-link-scroll", appearance: .aqua, directory: directory)
        #expect(window.frame.height > compactHeight)
        #expect(window.frame.height < compactHeight + 80)
        #expect(try #require(window.screen).visibleFrame.contains(window.frame))
        var smallFrame = window.frame
        smallFrame.size.height = 268
        window.setFrame(smallFrame, display: true)
        try await capture(window, name: "picker-link-small-screen", appearance: .aqua, directory: directory)
        #expect(window.frame.height == smallFrame.height)
        controller.sync()
        try await capture(window, name: "picker-link-scroll-restored", appearance: .aqua, directory: directory)
        func urlScrollView() throws -> NSScrollView {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
            let content = try #require(window.contentView)
            return try #require(descendants(content).compactMap { $0 as? NSScrollView }
                .first { ($0.documentView?.frame.height ?? 0) > $0.contentSize.height + 1 })
        }
        let scroll = try urlScrollView()
        let document = try #require(scroll.documentView)
        #expect(document.frame.width <= scroll.contentSize.width + 1)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: document.frame.height - scroll.contentSize.height))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.minY > 0)
        try await capture(window, name: "picker-link-scroll-end", appearance: .darkAqua, directory: directory)
        model.router.cancel()
        try await capture(window, name: "picker-link-scroll-next", appearance: .darkAqua, directory: directory)
        #expect(try urlScrollView().contentView.bounds.minY == 0)
        model.router.cancel()
        try await capture(window, name: "picker-link-compact-again", appearance: .aqua, directory: directory)
        #expect(window.frame.height < compactHeight + 30)
        model.router.cancel()
        model.router.rules = [WebsiteRule(host: "hypixelstudios.zendesk.com", targetID: "missing-profile")]
        model.router.enqueue([URL(string: "https://hypixelstudios.zendesk.com/agent/tickets/90493")!])
        try await capture(window, name: "picker-link-unavailable", appearance: .darkAqua, directory: directory)
        model.router.cancel()
        model.router.rules = []
        model.router.enqueue([url])
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
    func incomingLinksResumePickerFromSettingsAndReopen() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "local.switcheroo.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(defaults: defaults) { _, _ in Issue.record("Unexpected launch") }
        model.finishSetup()
        let delegate = AppDelegate(model: model)
        let previousMenu = app.mainMenu
        let previousWindows = Set(app.windows.map(\.windowNumber))
        defer {
            while model.router.current != nil { model.router.cancel() }
            for window in app.windows where !previousWindows.contains(window.windowNumber) { window.close() }
            app.mainMenu = previousMenu
        }
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        model.apply(CatalogSnapshot(targets: targets()))
        let first = URL(string: "https://example.com/first")!
        let second = URL(string: "https://example.com/second")!

        for minimized in [false, true] {
            _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: false)
            let settings = try #require(app.windows.first { $0.title == "Switcheroo Settings" && $0.isVisible })
            if minimized { settings.miniaturize(nil) }
            delegate.application(app, open: [first, second])
            #expect(!settings.isVisible)
            let picker = try #require(app.windows.first { $0.title == "Switcheroo" && $0.isVisible })
            #expect(model.router.pending.map(\.url) == [first, second])

            _ = delegate.applicationShouldHandleReopen(app, hasVisibleWindows: true)
            #expect(picker.isVisible)
            #expect(!settings.isVisible)

            model.showSettings?()
            #expect(settings.isVisible)
            #expect(!picker.isVisible)
            settings.close()
            #expect(picker.isVisible)
            #expect(model.router.current?.url == first)
            model.router.cancel()
            #expect(model.router.current?.url == second)
            model.router.cancel()
            #expect(!picker.isVisible)
            for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHEROO_CAPTURE_DIR"] != nil))
    func startupLinkTakesPriorityOverSetup() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "local.switcheroo.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(defaults: defaults) { _, _ in Issue.record("Unexpected launch") }
        let delegate = AppDelegate(model: model)
        let previousMenu = app.mainMenu
        let previousWindows = Set(app.windows.map(\.windowNumber))
        defer {
            while model.router.current != nil { model.router.cancel() }
            for window in app.windows where !previousWindows.contains(window.windowNumber) { window.close() }
            app.mainMenu = previousMenu
        }
        let url = URL(string: "https://example.com/startup")!
        delegate.application(app, open: [url])
        delegate.applicationDidFinishLaunching(Notification(name: NSApplication.didFinishLaunchingNotification))
        for _ in 0..<100 where model.isRefreshing { try await Task.sleep(for: .milliseconds(10)) }
        model.apply(CatalogSnapshot(targets: targets()))
        #expect(model.router.current?.url == url)
        #expect(app.windows.contains { $0.title == "Switcheroo" && $0.isVisible })
        #expect(!app.windows.contains { $0.title == "Switcheroo Settings" && $0.isVisible })
        #expect(!model.preferences.hasCompletedSetup)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHEROO_CAPTURE_DIR"] != nil))
    func nativePickerEscapeDismissesThroughApplicationEvents() async throws {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "local.switcheroo.tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var opened = false
        let model = AppModel(defaults: defaults) { _, _ in opened = true }
        model.apply(CatalogSnapshot(targets: targets()))
        let controller = PickerController(model: model)
        model.router.stateDidChange = { controller.sync() }
        let url = URL(string: "https://example.com/cancel")!
        model.router.enqueue([url])
        let window = try #require(app.windows.first { $0.title == "Switcheroo" && $0.isVisible })
        defer { controller.suspend(); window.close() }
        try await Task.sleep(for: .milliseconds(150))
        #expect(window.isKeyWindow)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        app.sendEvent(escape)
        #expect(model.router.current == nil)
        #expect(!window.isVisible)
        #expect(!opened)

        let nextURL = URL(string: "https://example.com/next")!
        model.router.enqueue([url, nextURL])
        app.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
        #expect(model.router.current?.url == nextURL)
        #expect(model.router.pending.count == 1)
        #expect(window.isVisible)
        app.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
        #expect(model.router.current == nil)
        #expect(!window.isVisible)
        #expect(!opened)
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
