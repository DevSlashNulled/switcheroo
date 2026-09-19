import AppKit

// Invoked by install.sh after a successful build. No privileged helper or sudo needed.
struct InstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func bundleIdentifier(at url: URL) throws -> String? {
    let data = try Data(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
    let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    return info?["CFBundleIdentifier"] as? String
}

func run(_ executable: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw InstallError(message: "\(executable) failed (exit \(process.terminationStatus)).")
    }
}

func install() throws {
    guard (2...3).contains(CommandLine.arguments.count) else {
        throw InstallError(message: "Run scripts/install.sh [applications-directory].")
    }
    let fm = FileManager.default
    let identifier = "local.switcheroo.app"
    let source = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    let systemApps = URL(fileURLWithPath: "/Applications", isDirectory: true)
    let userApps = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
    let applications: URL
    if CommandLine.arguments.count == 3 {
        applications = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
    } else if fm.fileExists(atPath: systemApps.appendingPathComponent("Switcheroo.app").path) {
        applications = systemApps
    } else if fm.fileExists(atPath: userApps.appendingPathComponent("Switcheroo.app").path) {
        applications = userApps
    } else {
        applications = fm.isWritableFile(atPath: systemApps.path) ? systemApps : userApps
    }
    let destination = applications.appendingPathComponent("Switcheroo.app", isDirectory: true)
    guard source.resolvingSymlinksInPath() != destination.resolvingSymlinksInPath(),
          applications.pathExtension != "app" else {
        throw InstallError(message: "Choose an Applications folder, separate from the build output.")
    }
    guard try bundleIdentifier(at: source) == identifier else {
        throw InstallError(message: "The build is not a Switcheroo app.")
    }
    let updating = fm.fileExists(atPath: destination.path)
    if updating {
        guard try destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
              try bundleIdentifier(at: destination) == identifier else {
            throw InstallError(message: "Won’t replace \(destination.path): it is not a regular Switcheroo app.")
        }
    }
    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
    let staging = applications.appendingPathComponent(".switcheroo-install-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: staging, withIntermediateDirectories: false)
    var keepBackup = false
    defer { if !keepBackup { try? fm.removeItem(at: staging) } }
    let candidate = staging.appendingPathComponent("Switcheroo.app")
    let backup = staging.appendingPathComponent("Previous.app")
    try fm.copyItem(at: source, to: candidate)
    try run("/usr/bin/codesign", ["--verify", "--strict", candidate.path])

    let running = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
    if !running.isEmpty {
        print("Closing Switcheroo. Finish any pending links or confirm Quit in its window.")
        fflush(stdout)
        for app in running { _ = app.terminate() }
        let deadline = Date().addingTimeInterval(20)
        while running.contains(where: { !$0.isTerminated }) && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw InstallError(message: "Switcheroo stayed open. Nothing was replaced. Finish your links, quit, and run the installer again.")
        }
    }

    var movedPrevious = false
    do {
        if updating {
            try fm.moveItem(at: destination, to: backup)
            movedPrevious = true
        }
        try fm.moveItem(at: candidate, to: destination)
    } catch {
        if movedPrevious {
            do { try fm.moveItem(at: backup, to: destination) }
            catch {
                keepBackup = true
                throw InstallError(message: "Couldn’t finish the update or restore it. Your previous app is preserved at \(backup.path).")
            }
        }
        throw error
    }
    print("\(updating ? "Updated" : "Installed") \(destination.path). Your settings have been preserved.")
    try run("/usr/bin/open", ["-a", destination.path])
    print("Switcheroo is open. Use its setup button to enable it as your link picker.")
}

do {
    try install()
} catch {
    FileHandle.standardError.write(Data("Install failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
