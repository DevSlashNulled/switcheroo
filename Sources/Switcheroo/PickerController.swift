import AppKit
import SwiftUI
import SwitcherooCore

private final class PickerPanel: NSPanel {
    var handleKey: ((NSEvent) -> Bool)?
    var handleCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { handleCancel?() }
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleKey?(event) == true { return }
        super.sendEvent(event)
    }
}

@MainActor
final class PickerController: NSObject {
    private let model: AppModel
    private let selection = PickerSelection()
    private let panel: PickerPanel
    private var linkID: UUID?
    private var urlHeight: CGFloat = 14
    private var isSuspended = false
    private var isHiding = false
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?

    init(model: AppModel) {
        self.model = model
        panel = PickerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        super.init()
        panel.title = "Switcheroo"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.handleKey = { [weak self] event in self?.handleKey(event) ?? false }
        panel.handleCancel = { [weak self] in self?.model.router.cancel() }
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true
        let content = NSHostingView(rootView: PickerView(model: model, selection: selection) { [weak self] height in
            guard let self, self.urlHeight != height else { return }
            self.urlHeight = height
            self.sync()
        })
        content.autoresizingMask = [.width, .height]
        background.addSubview(content)
        panel.contentView = background
        content.frame = background.bounds
    }

    func sync() {
        guard model.router.isPresented, let current = model.router.current, !isSuspended else {
            hide()
            return
        }
        if linkID != current.id {
            linkID = current.id
            selection.index = 0
            selection.remember = false
        }
        selection.index = min(selection.index, max(0, model.visibleTargets.count - 1))
        let pointer = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main else { return }
        let frame = PickerPlacement.frame(pointer: pointer, screen: screen.visibleFrame,
            targetCount: model.visibleTargets.count, hasMessage: model.router.message != nil,
            urlHeight: urlHeight, previousFrame: panel.isVisible ? panel.frame : nil)
        panel.setFrame(frame, display: true)
        if !panel.isVisible || !panel.isKeyWindow {
            NSApp.activate()
            panel.makeKeyAndOrderFront(nil)
        }
        observeOutsideClicks()
    }

    func suspend() { isSuspended = true; hide() }
    func resume() { isSuspended = false; sync() }

    private func hide() {
        isHiding = true
        if let monitor = globalMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMouseMonitor { NSEvent.removeMonitor(monitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        panel.orderOut(nil)
        isHiding = false
    }

    private func observeOutsideClicks() {
        guard globalMouseMonitor == nil, localMouseMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] _ in
            MainActor.assumeIsolated { self?.outsideMouseDown() }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, event.window !== self.panel { self.outsideMouseDown() }
            }
            return event
        }
    }

    private func outsideMouseDown() {
        guard !isHiding, !isSuspended, panel.isVisible,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        model.router.cancel()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "c":
                if let url = model.router.current?.url {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
                return true
            case ",": model.showSettings?(); return true
            default: return false
            }
        }
        guard !model.router.isLaunching else { return true }
        let targets = model.visibleTargets
        switch event.keyCode {
        case 53: panel.cancelOperation(nil)
        case 123: selection.index = max(0, selection.index - 1)
        case 124: selection.index = min(max(0, targets.count - 1), selection.index + 1)
        case 36, 76:
            if targets.indices.contains(selection.index) {
                model.router.choose(targets[selection.index].id, remember: selection.remember)
            }
        case 49: selection.remember.toggle()
        default:
            guard let characters = event.charactersIgnoringModifiers, let number = Int(characters),
                  (1...9).contains(number), targets.indices.contains(number - 1) else { return false }
            model.router.choose(targets[number - 1].id, remember: selection.remember)
        }
        return true
    }
}
