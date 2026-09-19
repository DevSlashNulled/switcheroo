import AppKit
import SwitcherooCore

struct LaunchFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
enum BrowserLauncher {
    static func open(_ target: BrowserTarget, url: URL) async throws {
        let app = target.installation.applicationURL
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw LaunchFailure(message: "\(target.browserName) is no longer installed. Refresh choices and select another browser.")
        }
        if let directory = target.profileDirectory, let root = target.installation.dataDirectory {
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            var isDirectory: ObjCBool = false
            guard ProfileParser.isValidDirectory(directory),
                  FileManager.default.fileExists(atPath: root.appendingPathComponent(directory).path,
                                                 isDirectory: &isDirectory), isDirectory.boolValue else {
                throw LaunchFailure(message: "The \(target.name) profile is unavailable. Refresh choices or grant profile access in Settings.")
            }
            guard let arguments = target.launchArguments(for: url) else {
                throw LaunchFailure(message: "The profile’s browser data folder is unavailable.")
            }
            try await runOpen(arguments, name: target.name)
        } else {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            configuration.addsToRecentItems = false
            try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
        }
    }

    private static func runOpen(_ arguments: [String], name: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                if process.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: LaunchFailure(
                        message: "Couldn’t open \(name). The link is still here; refresh choices or try again."
                    ))
                }
            }
            do { try process.run() } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
