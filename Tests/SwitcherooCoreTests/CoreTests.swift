import Foundation
import CoreGraphics
import Testing
@testable import SwitcherooCore

private let brave = BrowserInstallation(family: .brave,
    applicationURL: URL(fileURLWithPath: "/Applications/Brave Browser.app"),
    dataDirectory: URL(fileURLWithPath: "/tmp/Switcheroo Browser Data"))
private let personal = BrowserTarget(installation: brave, profileDirectory: "Default", name: "Personal")
private let work = BrowserTarget(installation: brave, profileDirectory: "Profile 1", name: "Work")

@Test func profilesUseDirectoryIdentityAndFilterMissingOrUnsafeEntries() throws {
    let data = try JSONSerialization.data(withJSONObject: ["profile": ["info_cache": [
        "Default": ["name": "Personal"], "Profile 1": ["name": "Personal"],
        "Deleted": ["name": "Deleted"], "../outside": ["name": "Unsafe"],
        "Guest Profile": ["name": "Guest"], "System Profile": ["name": "System"],
        "Hidden": ["name": "Hidden", "is_omitted": true], "Empty": ["name": "  "],
    ] as [String: [String: Any]]]])
    let targets = try ProfileParser.parse(data, installation: brave,
        existingDirectories: ["Default", "Profile 1", "../outside", "Guest Profile", "System Profile", "Hidden", "Empty"])
    #expect(Set(targets.map(\.profileDirectory)) == ["Default", "Profile 1", "Empty"])
    #expect(targets.filter { $0.name == "Personal" }.count == 2)
    #expect(Set(targets.map(\.id)).count == targets.count)
    #expect(targets.first { $0.profileDirectory == "Empty" }?.name == "Empty")
    let renamed = BrowserTarget(installation: brave, profileDirectory: "Default", name: "Renamed")
    #expect(renamed.id == personal.id)
}

@Test func malformedMetadataDoesNotInventDefaultProfiles() {
    for input in ["not json", "{}", #"{"profile":{"info_cache":[]}}"#] {
        #expect(throws: (any Error).self) {
            try ProfileParser.parse(Data(input.utf8), installation: brave, existingDirectories: ["Default"])
        }
    }
}

@Test(arguments: ["https://EXAMPLE.COM./path?x=1#fragment", "http://example.com:8080/other"])
func hostsNormalizeWithoutLosingTheURL(_ text: String) throws {
    let url = try #require(URL(string: text))
    let link = try #require(PendingLink(url: url))
    #expect(link.host == "example.com")
    #expect(link.url.absoluteString == url.absoluteString)
}

@Test func inputValidation() {
    #expect(PendingLink(url: URL(string: "file:///tmp/page")!) == nil)
    #expect(PendingLink(url: URL(string: "mailto:test@example.com")!) == nil)
    #expect(PendingLink.host(fromInput: "  GITHUB.COM.  ") == "github.com")
    #expect(PendingLink.host(fromInput: "*.github.com") == nil)
    #expect(PendingLink.host(fromInput: "user@example.com") == nil)
    #expect(PendingLink.host(fromInput: "bad host") == nil)
}

@Test(arguments: [
    "https://example.com/a%20b?q=hello%20world#part",
    "https://example.com/café?q=日本語",
    "https://example.com/?q=';$(touch%20/tmp/nope);`whoami`&x=1#frag",
])
func launchPreservesOneURLArgument(_ text: String) throws {
    let url = try #require(URL(string: text))
    let arguments = try #require(work.launchArguments(for: url))
    #expect(arguments.prefix(4) == ["-n", "-a", "/Applications/Brave Browser.app", "--args"])
    #expect(arguments.contains("--profile-directory=Profile 1"))
    #expect(arguments.contains("--user-data-dir=/tmp/Switcheroo Browser Data"))
    #expect(arguments.suffix(2) == ["--", url.absoluteString])
    #expect(arguments.count == 8)
}

@Test func preferencesRoundTripAndOrderSurviveProfileRename() throws {
    var preferences = Preferences()
    preferences.orderedTargetIDs = [work.id, personal.id]
    preferences.hiddenTargetIDs = [personal.id]
    preferences.folderBookmarks = [brave.id: Data([1, 2, 3])]
    preferences.rules = [WebsiteRule(host: "github.com", targetID: work.id)]
    preferences.hasCompletedSetup = true
    let decoded = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(preferences))
    #expect(decoded == preferences)
    #expect(decoded.ordered([personal, work]).map(\.id) == [work.id, personal.id])
}

@Test func placementStaysWithinEveryScreenEdgeAndSupportsNegativeOrigins() {
    for screen in [CGRect(x: 0, y: 0, width: 1440, height: 900),
                   CGRect(x: -1920, y: 120, width: 1920, height: 1080),
                   CGRect(x: 0, y: 0, width: 400, height: 300)] {
        for pointer in [screen.origin, CGPoint(x: screen.maxX, y: screen.maxY),
                        CGPoint(x: screen.minX, y: screen.maxY), CGPoint(x: screen.maxX, y: screen.minY)] {
            let frame = PickerPlacement.frame(pointer: pointer, screen: screen, targetCount: 20, hasMessage: true)
            #expect(screen.insetBy(dx: 16, dy: 16).contains(frame))
        }
    }
}

@MainActor
private final class LaunchProbe {
    var calls: [(String, URL)] = []
    var failure = false
    var suspended = false
    var continuation: CheckedContinuation<Void, Never>?
    enum Failure: Error { case expected }

    func open(_ target: BrowserTarget, _ url: URL) async throws {
        calls.append((target.id, url))
        if suspended { await withCheckedContinuation { continuation = $0 } }
        if failure { throw Failure.expected }
    }
}

@MainActor
private func settle(_ condition: () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
    }
    #expect(condition(), "Expected asynchronous routing to settle")
}

@Suite @MainActor
struct RouterTests {
    @Test func earlyEventsWaitForDiscoveryAndCancellationAdvances() {
        let router = LinkRouter { _, _ in }
        let urls = [URL(string: "https://one.example")!, URL(string: "https://two.example")!]
        router.enqueue(urls)
        #expect(!router.isPresented)
        #expect(router.pending.count == 2)
        router.updateTargets([personal, work])
        #expect(router.isPresented)
        #expect(router.current?.url == urls[0])
        router.cancel()
        #expect(router.current?.url == urls[1])
        router.cancel()
        #expect(router.current == nil)
        #expect(!router.isPresented)
    }

    @Test func arrivalDuringLaunchCannotReplaceOrDoubleOpenTheCurrentLink() async {
        let probe = LaunchProbe()
        probe.suspended = true
        let router = LinkRouter(launch: probe.open)
        var remembered: [WebsiteRule] = []
        router.didRemember = { remembered.append($0) }
        router.updateTargets([personal, work])
        let first = URL(string: "https://one.example/path?token=123#frag")!
        router.enqueue([first, URL(string: "https://two.example")!])
        router.choose(personal.id, remember: true)
        router.choose(work.id, remember: true)
        router.cancel()
        router.enqueue([URL(string: "https://three.example")!])
        await settle { probe.continuation != nil }
        #expect(router.pending.count == 3)
        #expect(probe.calls.count == 1)
        #expect(probe.calls.first?.1 == first)
        probe.continuation?.resume()
        await settle { !router.isLaunching }
        #expect(router.current?.host == "two.example")
        #expect(router.pending.count == 2)
        #expect(remembered == [WebsiteRule(host: "one.example", targetID: personal.id)])
    }

    @Test func failureRetainsTheLinkAndDoesNotSaveARuleOrRetry() async {
        let probe = LaunchProbe()
        probe.failure = true
        let router = LinkRouter(launch: probe.open)
        router.updateTargets([personal])
        router.enqueue([URL(string: "https://example.com")!])
        let requestID = router.current?.id
        router.choose(personal.id, remember: true)
        await settle { !router.isLaunching }
        #expect(router.current?.id == requestID)
        #expect(router.isPresented)
        #expect(router.message != nil)
        #expect(router.rules.isEmpty)
        router.updateTargets([personal])
        #expect(probe.calls.count == 1)
        probe.failure = false
        router.choose(personal.id, remember: false)
        await settle { !router.isLaunching }
        #expect(router.current == nil)
    }

    @Test func exactRulesDoNotMatchSubdomainsOrSuffixAttacks() async {
        let probe = LaunchProbe()
        let router = LinkRouter(launch: probe.open)
        router.updateTargets([personal, work])
        router.rules = [WebsiteRule(host: "github.com", targetID: work.id)]
        router.enqueue([URL(string: "https://GITHUB.COM./org?x=1#part")!])
        await settle { router.current == nil }
        #expect(probe.calls.first?.0 == work.id)
        for text in ["https://sub.github.com", "https://github.com.evil.example"] {
            router.enqueue([URL(string: text)!])
            #expect(router.isPresented)
            #expect(probe.calls.count == 1)
            router.cancel()
        }
    }

    @Test func disabledPausedAndMissingRulesShowThePicker() {
        let router = LinkRouter { _, _ in Issue.record("Unexpected launch") }
        router.updateTargets([personal])
        router.rules = [WebsiteRule(host: "example.com", targetID: personal.id, isEnabled: false)]
        router.enqueue([URL(string: "https://example.com")!])
        #expect(router.isPresented)
        router.cancel()
        router.rules = [WebsiteRule(host: "example.com", targetID: personal.id)]
        router.rulesPaused = true
        router.enqueue([URL(string: "https://example.com")!])
        #expect(router.isPresented)
        router.cancel()
        router.rulesPaused = false
        router.rules = [WebsiteRule(host: "example.com", targetID: work.id)]
        router.enqueue([URL(string: "https://example.com")!])
        #expect(router.isPresented)
        #expect(router.message?.contains("unavailable") == true)
    }

    @Test func rememberingReplacesOnlyTheSameHostname() async {
        let router = LinkRouter { _, _ in }
        router.updateTargets([personal, work])
        router.rulesPaused = true
        router.rules = [WebsiteRule(host: "example.com", targetID: personal.id),
                        WebsiteRule(host: "other.example", targetID: personal.id)]
        router.enqueue([URL(string: "https://example.com")!])
        router.choose(work.id, remember: true)
        await settle { !router.isLaunching }
        #expect(router.rules.count == 2)
        #expect(router.rules.first { $0.host == "example.com" }?.targetID == work.id)
        #expect(router.rules.first { $0.host == "other.example" }?.targetID == personal.id)
    }
}
