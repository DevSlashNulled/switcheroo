import AppKit
import SwiftUI

@main
@MainActor
enum SwitcherooApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var picker: PickerController!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        picker = PickerController(model: model)
        model.router.stateDidChange = { [weak self] in self?.picker.sync() }
        model.showSettings = { [weak self] in self?.showSettings() }
        model.menuDidChange = { [weak self] in self?.buildMenu() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.left.arrow.right", accessibilityDescription: "Switcheroo")
        statusItem.button?.toolTip = "Switcheroo"
        buildMenu()
        model.refresh()
        if !model.preferences.hasCompletedSetup {
            model.selectedTab = .choices
            showSettings()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        model.receive(urls)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) { model.refresh() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !model.router.pending.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Quit with pending links?"
        alert.informativeText = "\(model.router.pending.count) unopened link(s) will be discarded."
        alert.addButton(withTitle: "Keep Switcheroo Open")
        alert.addButton(withTitle: "Quit")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func windowWillClose(_ notification: Notification) { picker.resume() }

    @objc private func showSettings() {
        guard picker != nil else { return }
        picker.suspend()
        if settingsWindow == nil {
            let view = SettingsView(model: model) { [weak self] in self?.settingsWindow?.close() }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Switcheroo Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 640, height: 570))
            window.minSize = NSSize(width: 600, height: 480)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        model.updateSystemStatus()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func togglePause() { model.toggleRulesPaused() }
    @objc private func refreshChoices() { model.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    private func buildMenu() {
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        let pause = menu.addItem(withTitle: "Pause website rules", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        pause.state = model.router.rulesPaused ? .on : .off
        let refresh = menu.addItem(withTitle: "Refresh choices", action: #selector(refreshChoices), keyEquivalent: "")
        refresh.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Switcheroo", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        statusItem.menu = menu
        let mainMenu = NSMenu()
        let appMenu = NSMenuItem()
        mainMenu.addItem(appMenu)
        appMenu.submenu = menu.copy() as? NSMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        mainMenu.addItem(editItem)
        editItem.submenu = edit
        NSApp.mainMenu = mainMenu
    }
}
