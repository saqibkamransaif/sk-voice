import SwiftUI
import AppKit
import SKVoiceCore

struct DashboardView: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        TabView {
            HistoryTab(coordinator: coordinator)
                .tabItem { Label("History", systemImage: "clock") }
            SettingsTab(coordinator: coordinator)
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .frame(minWidth: 620, minHeight: 460)
    }
}

// MARK: - History

struct HistoryTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var search = ""
    @State private var entries: [HistoryEntry] = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history…", text: $search)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .padding([.horizontal, .top], 12)

            if entries.isEmpty {
                Spacer()
                Text(search.isEmpty ? "No dictations yet — hold Fn and speak."
                                    : "No matches.")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(entries) { entry in
                    HistoryRow(entry: entry) {
                        try? coordinator.history?.delete(id: entry.id)
                        reload()
                    }
                }
                .listStyle(.inset)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: search) { reload() }
        .onChange(of: coordinator.historyRevision) { reload() }
    }

    private func reload() {
        entries = coordinator.history?
            .recent(limit: 200, search: search.isEmpty ? nil : search) ?? []
    }
}

struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.mode == .refine ? "REFINE" : "DICTATE")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .foregroundStyle(entry.mode == .refine ? Color.indigo : Color.teal)
                    .background(entry.mode == .refine ? Color.indigo.opacity(0.15)
                                                      : Color.teal.opacity(0.15),
                                in: Capsule())
                Text(entry.appName).font(.caption).foregroundStyle(.secondary)
                Text(entry.createdAt, style: .relative).font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.finalText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy text")
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Delete entry")
            }
            Text(entry.finalText)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(4)
            if entry.mode == .refine, entry.rawTranscript != entry.finalText {
                Text("Raw: \(entry.rawTranscript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings

struct SettingsTab: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var newFind = ""
    @State private var newReplace = ""

    var body: some View {
        Form {
            Section("Hotkeys") {
                Toggle("Pause hotkeys", isOn: binding(\.hotkeysPaused))
                VStack(alignment: .leading) {
                    Text(String(format: "Hold threshold: %.2f s",
                                coordinator.settings.holdThreshold))
                    Slider(value: binding(\.holdThreshold), in: 0.15...0.6, step: 0.05)
                }
                Text("Hold **Fn** to dictate · hold **Fn + Ctrl** to refine with Claude")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Vocabulary") {
                ForEach(coordinator.settings.vocabulary) { rule in
                    HStack {
                        Text(rule.find)
                        Image(systemName: "arrow.right").foregroundStyle(.secondary)
                        Text(rule.replace).bold()
                        Spacer()
                        Button {
                            coordinator.settings.vocabulary.removeAll { $0.id == rule.id }
                            coordinator.applySettingsChange()
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("heard text", text: $newFind)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("replace with", text: $newReplace)
                    Button("Add") {
                        guard !newFind.isEmpty, !newReplace.isEmpty else { return }
                        coordinator.settings.vocabulary.append(
                            VocabRule(find: newFind, replace: newReplace))
                        newFind = ""
                        newReplace = ""
                        coordinator.applySettingsChange()
                    }
                }
            }

            Section("Refine (Claude)") {
                HStack {
                    Circle()
                        .fill(coordinator.sidecarHealthy ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(coordinator.sidecarHealthy ? "Sidecar connected"
                                                    : "Sidecar unavailable")
                        .font(.caption)
                    Spacer()
                    Button("Restart sidecar") { coordinator.restartSidecar() }
                }
                Picker("Model", selection: binding(\.modelOverride)) {
                    Text("Subscription default").tag(String?.none)
                    Text("Haiku (fastest)").tag(String?.some("haiku"))
                    Text("Sonnet").tag(String?.some("sonnet"))
                }
                VStack(alignment: .leading) {
                    Text("System prompt").font(.caption)
                    TextEditor(text: binding(\.refineSystemPrompt))
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 110)
                        .overlay(RoundedRectangle(cornerRadius: 4)
                            .stroke(.quaternary))
                }
            }

            Section("General") {
                LaunchAtLoginToggle()
            }
        }
        .formStyle(.grouped)
        .onSubmit { coordinator.applySettingsChange() }
    }

    /// Two-way binding into settings that persists + applies on change.
    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(
            get: { coordinator.settings[keyPath: keyPath] },
            set: { newValue in
                coordinator.settings[keyPath: keyPath] = newValue
                coordinator.applySettingsChange()
            })
    }
}
