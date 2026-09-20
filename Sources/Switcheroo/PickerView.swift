import SwiftUI
import SwitcherooCore

@MainActor @Observable
final class PickerSelection {
    var index = 0
    var remember = false
}

struct PickerView: View {
    let model: AppModel
    let selection: PickerSelection
    let onURLHeightChange: (CGFloat) -> Void
    @State private var urlHeight: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let link = model.router.current {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(link.host)
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.head)
                        ScrollView(.vertical) {
                            Text(link.url.absoluteString)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .onGeometryChange(for: CGFloat.self) { min(70, $0.size.height) } action: { height in
                                    urlHeight = height
                                    onURLHeightChange(height)
                                }
                        }
                        .frame(maxHeight: urlHeight)
                        .id(link.id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Open \(link.url.absoluteString)")
                    Button { copyLink() } label: {
                        Image(systemName: "doc.on.doc")
                    }.buttonStyle(.plain).help("Copy complete URL (⌘C)")
                        .accessibilityLabel("Copy complete URL")
                }.help(link.url.absoluteString)

                if model.visibleTargets.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "person.crop.circle.badge.exclamationmark").font(.largeTitle)
                        Text(model.isRefreshing ? "Finding your browsers…" : "Choose browsers and grant profile access in Settings.")
                            .font(.callout).multilineTextAlignment(.center)
                        Button("Open Settings") { openChoices() }
                    }.frame(maxWidth: .infinity, minHeight: 112)
                } else {
                    GeometryReader { viewport in
                        ScrollViewReader { proxy in
                            ScrollView(.horizontal) {
                                HStack(spacing: 12) {
                                    ForEach(Array(model.visibleTargets.enumerated()), id: \.element.id) { index, target in
                                        ProfileTile(target: target, icon: model.icon(for: target),
                                                    index: index, selected: selection.index == index) {
                                            model.router.choose(target.id, remember: selection.remember)
                                        }
                                        .id(target.id)
                                        .onHover { hovering in if hovering { selection.index = index } }
                                    }
                                }
                                .padding(4)
                                .frame(minWidth: viewport.size.width, minHeight: viewport.size.height)
                            }
                            .scrollIndicators(.hidden)
                            .onChange(of: selection.index) { _, index in
                                if model.visibleTargets.indices.contains(index) {
                                    proxy.scrollTo(model.visibleTargets[index].id, anchor: .center)
                                }
                            }
                        }
                    }.frame(height: 126)
                }

                if let message = model.router.message {
                    Label(message, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.orange).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Toggle(isOn: Binding(get: { selection.remember }, set: { selection.remember = $0 })) {
                        Text("Always use this choice for \(link.host)").lineLimit(1).help(link.host)
                    }.toggleStyle(.checkbox).font(.caption)
                    Spacer(minLength: 4)
                    if model.router.isLaunching {
                        ProgressView().controlSize(.small)
                    }
                    Button { model.showSettings?() } label: {
                        Image(systemName: "gearshape")
                    }.buttonStyle(.plain).help("Settings (⌘,)").accessibilityLabel("Settings")
                }
                HStack {
                    if !model.accessIssues.isEmpty {
                        Button("Some profiles need access") { openChoices() }
                            .buttonStyle(.link)
                    } else {
                        Text("← → to choose · return to open · esc to cancel").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.router.pending.count > 1 {
                        Text("\(model.router.pending.count) links queued").foregroundStyle(.secondary)
                    }
                }.font(.system(size: 10))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .disabled(model.router.isLaunching)
        .overlay { RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.12), lineWidth: 1) }
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func openChoices() {
        model.selectedTab = .choices
        model.showSettings?()
    }

    private func copyLink() {
        guard let url = model.router.current?.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }
}

private struct ProfileTile: View {
    let target: BrowserTarget
    let icon: NSImage
    let index: Int
    let selected: Bool
    let action: () -> Void
    private let colors: [Color] = [.blue, .purple, .orange, .teal, .pink, .indigo]

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(nsImage: icon).resizable().frame(width: 44, height: 44)
                    .overlay(alignment: .bottomTrailing) {
                        if target.profileDirectory != nil {
                            Text(target.initials).font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white).padding(4)
                                .background(colors[target.colorIndex], in: Circle())
                                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                                .offset(x: 6, y: 3)
                        }
                    }
                Text(target.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(target.profileDirectory == nil ? "Browser" : target.browserName)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                Text(index < 9 ? "\(index + 1)" : " ")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            .frame(width: 88, height: 118)
            .background(selected ? Color.accentColor.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor.opacity(0.6) : .clear) }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .help(target.profileDirectory == nil ? target.name : "\(target.name) — \(target.browserName)")
        .accessibilityLabel(target.profileDirectory == nil ? target.name : "\(target.browserName), \(target.name)")
        .accessibilityHint(index < 9 ? "Press \(index + 1) to open here" : "Open here")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
