import AppKit
import Testing

// Foreground handoffs need a LaunchServices-registered app with an AppKit run loop.
// A command-line test runner cannot establish the same activation state.
@MainActor
final class FocusTestDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let environment = ProcessInfo.processInfo.environment
            let resultURL = URL(fileURLWithPath: environment["SWITCHEROO_FOCUS_RESULT"]!)
            do {
                let bundle = Bundle(path: environment["SWITCHEROO_FOCUS_TEST_BUNDLE"]!)!
                try bundle.loadAndReturnError()
            } catch {
                print("Could not load the focus tests: \(error)")
                try? "1".write(to: resultURL, atomically: true, encoding: .utf8)
                exit(1)
            }
            let result: CInt = await Testing.__swiftPMEntryPoint()
            try? String(result).write(to: resultURL, atomically: true, encoding: .utf8)
            exit(result)
        }
    }
}

@main
@MainActor
enum FocusTestHost {
    static func main() {
        let app = NSApplication.shared
        let delegate = FocusTestDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
