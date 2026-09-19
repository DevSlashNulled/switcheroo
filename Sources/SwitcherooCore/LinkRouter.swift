import Foundation
import Observation

@MainActor @Observable
public final class LinkRouter {
    public private(set) var pending: [PendingLink] = []
    public private(set) var targets: [BrowserTarget] = []
    public private(set) var isPresented = false
    public private(set) var isLaunching = false
    public private(set) var message: String?
    public var rules: [WebsiteRule] = []
    public var rulesPaused = false
    public var current: PendingLink? { pending.first }

    @ObservationIgnored public var stateDidChange: (() -> Void)?
    @ObservationIgnored public var didRemember: ((WebsiteRule) -> Void)?
    @ObservationIgnored private let launch: (BrowserTarget, URL) async throws -> Void
    private var isReady = false

    public init(launch: @escaping (BrowserTarget, URL) async throws -> Void) {
        self.launch = launch
    }

    public func enqueue(_ urls: [URL]) {
        pending.append(contentsOf: urls.compactMap { PendingLink(url: $0) })
        advance()
    }

    public func updateTargets(_ targets: [BrowserTarget]) {
        self.targets = targets
        isReady = true
        advance()
        stateDidChange?()
    }

    public func choose(_ targetID: String, remember: Bool) {
        guard !isLaunching, let current,
              let target = targets.first(where: { $0.id == targetID }) else { return }
        startLaunch(target, link: current, remember: remember)
    }

    public func cancel() {
        guard !isLaunching, current != nil else { return }
        pending.removeFirst()
        isPresented = false
        message = nil
        advance()
    }

    private func advance() {
        guard isReady, !isLaunching, !isPresented else { return }
        guard let current else {
            stateDidChange?()
            return
        }
        message = nil
        if !rulesPaused, let rule = rules.first(where: { $0.isEnabled && $0.host == current.host }) {
            if let target = targets.first(where: { $0.id == rule.targetID }) {
                startLaunch(target, link: current, remember: false)
                return
            }
            message = "The saved choice for \(current.host) is unavailable. Choose another browser or profile."
        }
        isPresented = true
        stateDidChange?()
    }

    private func startLaunch(_ target: BrowserTarget, link: PendingLink, remember: Bool) {
        isLaunching = true
        message = nil
        stateDidChange?()
        Task {
            do {
                try await launch(target, link.url)
                if remember {
                    let rule = WebsiteRule(host: link.host, targetID: target.id)
                    rules.removeAll { $0.host == rule.host }
                    rules.append(rule)
                    didRemember?(rule)
                }
                pending.removeFirst()
                isLaunching = false
                isPresented = false
                advance()
            } catch {
                isLaunching = false
                isPresented = true
                message = error.localizedDescription
                stateDidChange?()
            }
        }
    }
}
