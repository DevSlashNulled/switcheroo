import AppKit
import Testing
import SwitcherooCore
@testable import Switcheroo

@Suite(.serialized) @MainActor
struct FocusTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SWITCHEROO_ROUTING_SMOKE_URL"] != nil))
    func chromiumPickerAndRuleFocus() async throws {
        let environment = ProcessInfo.processInfo.environment
        let baseText = try #require(environment["SWITCHEROO_ROUTING_SMOKE_URL"])
        let base = try #require(URL(string: baseText))
        let appPath = try #require(environment["SWITCHEROO_ROUTING_SMOKE_APP"])
        let rootPath = try #require(environment["SWITCHEROO_ROUTING_SMOKE_ROOT"])
        let reportsPath = try #require(environment["SWITCHEROO_ROUTING_SMOKE_REPORTS"])
        try #require([appPath, rootPath, reportsPath].allSatisfy { $0.hasPrefix("/") })
        try #require(["localhost", "127.0.0.1", "::1"].contains(base.host ?? ""))
        let applicationURL = URL(fileURLWithPath: appPath).resolvingSymlinksInPath()
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let reports = URL(fileURLWithPath: reportsPath)
        try #require(applicationURL.pathExtension == "app" && root.pathExtension != "app")
        let family = try #require([BrowserFamily.brave, .chrome, .edge].first {
            $0.bundleIdentifier == Bundle(url: applicationURL)?.bundleIdentifier
        })
        let installation = BrowserInstallation(family: family, applicationURL: applicationURL, dataDirectory: root)
        let choices = [BrowserTarget(installation: installation, profileDirectory: "Default", name: "Personal"),
                       BrowserTarget(installation: installation, profileDirectory: "Profile 1", name: "Work")]
        let snapshot = CatalogSnapshot(targets: choices)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let domain = "local.switcheroo.focus-tests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let model = AppModel(defaults: defaults)
        model.apply(snapshot)
        let controller = PickerController(model: model)
        let panel = try #require(app.windows.first { $0.title == "Switcheroo" })
        model.router.stateDidChange = { controller.sync() }
        defer {
            model.router.stateDidChange = nil
            controller.suspend()
            panel.close()
        }

        var browserPID: pid_t?
        func browser() -> NSRunningApplication? {
            NSWorkspace.shared.runningApplications.first {
                !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == applicationURL
                    && (browserPID == nil || $0.processIdentifier == browserPID)
            }
        }
        func browserIsFrontmost() -> Bool {
            guard let running = browser(), let frontmost = NSWorkspace.shared.frontmostApplication else { return false }
            return running.isActive && !running.isHidden && frontmost.processIdentifier == running.processIdentifier
                && frontmost.bundleURL?.resolvingSymlinksInPath() == applicationURL
        }
        try #require(browser() == nil, "The cold-launch case requires the copied browser to be stopped")

        for token in 0..<4 {
            let expectedProfile = token.isMultiple(of: 2) ? "personal" : "work"
            if token > 0 {
                try await wait("Browser readiness before token \(token)") {
                    browser()?.isFinishedLaunching == true && browser()?.activationPolicy == .regular
                }
            }
            if token == 2 {
                let running = try #require(browser())
                running.hide()
                try await wait("Copied browser hides before token 2") { running.isHidden }
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
            try await wait("Test app activation before token \(token)") {
                app.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == NSRunningApplication.current.processIdentifier
            }

            var components = try #require(URLComponents(url: base, resolvingAgainstBaseURL: false))
            components.queryItems = [URLQueryItem(name: "token", value: String(token))]
            if token < 2 { components.queryItems?.append(URLQueryItem(name: "seed", value: expectedProfile)) }
            let url = try #require(components.url)
            if token == 3 {
                model.saveRule(WebsiteRule(host: try #require(PendingLink(url: url)?.host), targetID: choices[1].id))
            }
            model.router.enqueue([url])
            if token < 3 {
                try await wait("Picker focus for token \(token)") { panel.isVisible && panel.isKeyWindow && app.isActive }
                let number = token.isMultiple(of: 2) ? "1" : "2"
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: number,
                    charactersIgnoringModifiers: number, isARepeat: false, keyCode: number == "1" ? 18 : 19))
                app.sendEvent(event)
            }
            try #require(model.router.isLaunching)
            #expect(!panel.isVisible, "Picker must hide before the browser launch starts")
            model.apply(snapshot)
            #expect(!panel.isVisible, "Catalog refresh must not reactivate the picker during launch")

            let reportURL = reports.appendingPathComponent("\(token).json")
            do {
                try await wait("Browser foreground and page focus report for token \(token)", timeout: .seconds(30)) {
                    model.router.pending.isEmpty && browserIsFrontmost()
                        && FileManager.default.fileExists(atPath: reportURL.path)
                }
            } catch {
                print("Routing state: pending=\(model.router.pending.count), message=\(model.router.message ?? "none")")
                print("Browser: pid=\(browser()?.processIdentifier ?? -1), active=\(browser()?.isActive ?? false), hidden=\(browser()?.isHidden ?? false)")
                print("Frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleURL?.path ?? "none")")
                print("Page report: \((try? String(contentsOf: reportURL, encoding: .utf8)) ?? "missing")")
                throw error
            }
            let running = try #require(browser())
            if token == 0 { browserPID = running.processIdentifier }
            #expect(running.processIdentifier == browserPID)
            let report = try JSONDecoder().decode(FocusReport.self, from: Data(contentsOf: reportURL))
            #expect(report.token == String(token))
            #expect(report.profile == expectedProfile)
            #expect(report.focused)
            try await Task.sleep(for: .milliseconds(300))
            #expect(browserIsFrontmost(), "Browser must retain focus after token \(token)")
            #expect(!panel.isVisible)
            print("PASS \(token + 1): \(expectedProfile) page and browser are foreground")
        }
    }

    private func wait(_ description: String, timeout: Duration = .seconds(10), until condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline { try await Task.sleep(for: .milliseconds(25)) }
        try #require(condition(), "Timed out: \(description)")
    }

    private struct FocusReport: Decodable {
        let token: String
        let profile: String
        let focused: Bool
    }
}
