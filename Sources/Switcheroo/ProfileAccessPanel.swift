import AppKit

@MainActor
final class ProfileAccessPanel: NSObject, NSOpenSavePanelDelegate {
    let panel = NSOpenPanel()
    private let directory: URL

    init(browserName: String, directory: URL) {
        self.directory = URL(fileURLWithPath: directory.path, isDirectory: true).resolvingSymlinksInPath()
        super.init()
        panel.title = "Connect \(browserName)"
        panel.message = "Click Allow to show your \(browserName) profiles. The correct folder is already open. Switcheroo won’t change your browser data."
        panel.prompt = "Allow"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = self.directory
        panel.delegate = self
    }

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        let candidate = url.resolvingSymlinksInPath().path
        return candidate == directory.path || directory.path.hasPrefix(candidate.hasSuffix("/") ? candidate : candidate + "/")
    }

    func panel(_ sender: Any, validate url: URL) throws {
        guard url.resolvingSymlinksInPath().path == directory.path else {
            throw LaunchFailure(message: "Use the folder that opened with this dialog. Cancel and click Connect again to return to it.")
        }
    }

    func begin(completion: @escaping (URL?) -> Void) {
        let finished: (NSApplication.ModalResponse) -> Void = { [self] response in
            completion(response == .OK ? panel.url : nil)
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finished)
        } else {
            panel.begin(completionHandler: finished)
        }
    }
}
