import ServiceManagement
import SwiftUI
import SwitcherooCore

struct SettingsView: View {
    @Bindable var model: AppModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            if !model.preferences.hasCompletedSetup {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Welcome to Switcheroo", systemImage: "arrow.left.arrow.right")
                        .font(.title2.weight(.semibold))
                    Text("Your profiles appear automatically. Keep the ones you use, then let Switcheroo handle your links.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(24)
                Divider()
                ChoiceSettings(model: model).padding(.top, 20)
            } else {
                Picker("Settings section", selection: $model.selectedTab) {
                    ForEach(AppModel.SettingsTab.allCases, id: \.self) { tab in Text(tab.rawValue).tag(tab) }
                }.pickerStyle(.segmented).labelsHidden().padding(20)

                Group {
                    switch model.selectedTab {
                    case .general: GeneralSettings(model: model)
                    case .choices: ChoiceSettings(model: model)
                    case .rules: RuleSettings(model: model)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            Divider()
            if !model.preferences.hasCompletedSetup {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.isDefaultBrowser ? "You’re ready. Click a link in another app to choose where it opens."
                         : "macOS will ask to use Switcheroo as your default browser. You’ll still browse in the profiles you choose.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("Set up later") { model.finishSetup(); close() }
                        Spacer()
                        if model.isRequestingDefaultBrowser { ProgressView().controlSize(.small) }
                        Button(model.isDefaultBrowser ? "Start using Switcheroo" : "Make Switcheroo my link picker") {
                            let finish = { model.finishSetup(); close() }
                            if model.isDefaultBrowser { finish() }
                            else { model.makeDefaultBrowser(onSuccess: finish) }
                        }.buttonStyle(.borderedProminent)
                            .disabled(model.visibleTargets.isEmpty || model.isRequestingDefaultBrowser)
                    }
                }
                .padding(20)
            } else {
                Text("Switcheroo · Links, in the right place.")
                    .font(.caption).foregroundStyle(.secondary).padding(16)
            }
        }
        .frame(minWidth: 600, idealWidth: 640, minHeight: 460, idealHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Switcheroo", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("OK") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .onAppear { model.updateSystemStatus() }
    }
}

private struct GeneralSettings: View {
    let model: AppModel
    var body: some View {
        Form {
            Section {
                LabeledContent("Default browser") {
                    Label(model.isDefaultBrowser ? "Switcheroo" : "Another app",
                          systemImage: model.isDefaultBrowser ? "checkmark.circle.fill" : "globe")
                        .foregroundStyle(model.isDefaultBrowser ? .green : .secondary)
                }
                Button("Make Switcheroo the default browser") { model.makeDefaultBrowser() }
                    .disabled(model.isDefaultBrowser || model.visibleTargets.isEmpty || model.isRequestingDefaultBrowser)
            } footer: {
                Text("Switcheroo passes each link to your selected browser. Links clicked inside a web page stay in that browser.")
            }
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { [.enabled, .requiresApproval].contains(model.loginStatus) },
                    set: { model.setLaunchAtLogin($0) }
                ))
                Toggle("Pause website rules", isOn: Binding(
                    get: { model.router.rulesPaused }, set: { _ in model.toggleRulesPaused() }
                ))
            } footer: {
                Text("Paused rules resume when Switcheroo restarts. Install the app in Applications before enabling launch at login.")
            }
        }.formStyle(.grouped)
    }
}

private struct ChoiceSettings: View {
    let model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your browsers and profiles").font(.headline)
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button("Refresh") { model.refresh() }.disabled(model.isRefreshing)
            }
            Text("Uncheck any you don’t use. Use the arrows to change their order.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(model.allTargets.enumerated()), id: \.element.id) { index, target in
                        HStack(spacing: 12) {
                            Toggle(isOn: Binding(
                                get: { !model.preferences.hiddenTargetIDs.contains(target.id) },
                                set: { model.setVisible(target, $0) }
                            )) { EmptyView() }.toggleStyle(.checkbox)
                                .accessibilityLabel("Show \(target.browserName), \(target.name)")
                            Image(nsImage: model.icon(for: target)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.name).lineLimit(1)
                                Text(target.profileDirectory == nil ? "Browser default" : target.browserName)
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { model.move(target, by: -1) } label: { Image(systemName: "chevron.up") }
                                .disabled(index == 0).help("Move earlier")
                                .accessibilityLabel("Move \(target.name) earlier")
                            Button { model.move(target, by: 1) } label: { Image(systemName: "chevron.down") }
                                .disabled(index == model.allTargets.count - 1).help("Move later")
                                .accessibilityLabel("Move \(target.name) later")
                        }.padding(.vertical, 8)
                        Divider()
                    }
                    ForEach(model.accessIssues) { issue in
                        HStack(spacing: 12) {
                            Image(nsImage: model.icon(for: BrowserTarget(installation: issue.installation,
                                name: issue.installation.family.name))).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(issue.installation.family.name).font(.headline)
                                Text(issue.message).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button(issue.actionTitle) { model.resolve(issue) }
                        }.padding(.vertical, 12)
                        Divider()
                    }
                    if model.allTargets.isEmpty && model.accessIssues.isEmpty && !model.isRefreshing {
                        Text("Install Brave, Chrome, Edge, Safari, or Firefox, then refresh.")
                            .foregroundStyle(.secondary).padding(.vertical, 24)
                    }
                }
            }
            if model.preferences.hasCompletedSetup {
                Text("Hiding a choice removes its tile. Existing website rules can still use it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(.horizontal, 24).padding(.bottom, 20)
    }
}

private struct RuleSettings: View {
    let model: AppModel
    @State private var editing: RuleDraft?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Exact website matches").font(.headline)
                Spacer()
                Button("Add Rule") { editing = RuleDraft(targetID: model.allTargets.first?.id ?? "") }
                    .disabled(model.allTargets.isEmpty)
            }
            Text("A rule for github.com matches that hostname, including all paths. Subdomains remain separate.")
                .font(.caption).foregroundStyle(.secondary)
            List {
                ForEach(model.preferences.rules) { rule in
                    HStack {
                        Toggle(isOn: Binding(get: { rule.isEnabled }, set: { enabled in
                            var updated = rule
                            updated.isEnabled = enabled
                            model.saveRule(updated)
                        })) { EmptyView() }.toggleStyle(.checkbox).accessibilityLabel("Enable rule for \(rule.host)")
                        VStack(alignment: .leading, spacing: 3) {
                            Text(rule.host).font(.system(.body, design: .monospaced))
                            if let target = model.allTargets.first(where: { $0.id == rule.targetID }) {
                                Text("\(target.browserName) · \(target.name)").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Choice unavailable; the picker will appear").font(.caption).foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button("Edit") { editing = RuleDraft(rule: rule) }
                        Button { model.deleteRule(rule.host) } label: { Image(systemName: "trash") }
                            .help("Delete rule").accessibilityLabel("Delete rule for \(rule.host)")
                    }.padding(.vertical, 5)
                }
            }.overlay {
                if model.preferences.rules.isEmpty {
                    ContentUnavailableView("Ask every time", systemImage: "arrow.triangle.branch",
                        description: Text("Remember a website from the picker, or add a rule here."))
                }
            }
        }.padding(.horizontal, 24).padding(.bottom, 20)
            .sheet(item: $editing) { draft in
                RuleEditor(model: model, draft: draft) { editing = nil }
            }
    }
}

private struct RuleDraft: Identifiable {
    let id = UUID()
    var originalHost: String?
    var host = ""
    var targetID: String
    var enabled = true
    init(targetID: String) { self.targetID = targetID }
    init(rule: WebsiteRule) {
        originalHost = rule.host
        host = rule.host
        targetID = rule.targetID
        enabled = rule.isEnabled
    }
}

private struct RuleEditor: View {
    let model: AppModel
    @State var draft: RuleDraft
    let close: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.originalHost == nil ? "Add website rule" : "Edit website rule").font(.headline)
            TextField("Website hostname, e.g. github.com", text: $draft.host)
                .textFieldStyle(.roundedBorder)
            Picker("Open in", selection: $draft.targetID) {
                if !model.allTargets.contains(where: { $0.id == draft.targetID }) {
                    Text("Choose a browser or profile").tag(draft.targetID)
                }
                ForEach(model.allTargets) { target in
                    Text("\(target.browserName) · \(target.name)").tag(target.id)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let host = PendingLink.host(fromInput: draft.host) else { return }
                    model.saveRule(WebsiteRule(host: host, targetID: draft.targetID, isEnabled: draft.enabled),
                                   replacing: draft.originalHost)
                    close()
                }.keyboardShortcut(.defaultAction)
                    .disabled(PendingLink.host(fromInput: draft.host) == nil || !model.allTargets.contains(where: { $0.id == draft.targetID }))
            }
        }.padding(24).frame(width: 430)
    }
}
