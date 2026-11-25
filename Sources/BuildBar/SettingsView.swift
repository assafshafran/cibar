import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var ghMessage: String?
    @State private var launchAtLogin = false
    @State private var showRepoPicker = false

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                HStack {
                    TextField("URL", text: $pasted, prompt: Text("Paste a pipeline or repository URL"))
                        .labelsHidden()
                        .onSubmit(addPasted)
                    Button("Add", action: addPasted).disabled(pasted.trimmingCharacters(in: .whitespaces).isEmpty)
                    Menu {
                        Button("Azure DevOps project") { settings.sources.append(Source(provider: .azure)) }
                        Button("GitHub repository") { settings.sources.append(Source(provider: .github)) }
                    } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("Add manually")
                }
                if let pasteError { Text(pasteError).font(.caption).foregroundStyle(.red) }
                ForEach($settings.sources) { $source in
                    SourceEditor(source: $source, error: monitor.errors[source.id]) {
                        settings.sources.removeAll { $0.id == source.id }
                    }
                }
            } header: {
                Text("Watching")
            } footer: {
                Text("e.g. https://dev.azure.com/org/project/_build?definitionId=105 or https://github.com/owner/repo")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Azure DevOps") {
                TokenField(placeholder: "Paste your Azure DevOps token here", saved: $settings.azureToken) {
                    Task { await monitor.refresh() }
                }
                HStack {
                    Text("Scope needed: Build (Read). Stored privately on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let org = settings.sources.first(where: { $0.provider == .azure && !$0.organization.isEmpty })?.organization,
                       let url = URL(string: "https://dev.azure.com/\(org)/_usersSettings/tokens") {
                        Link("Create a token…", destination: url).font(.caption)
                    }
                }
            }

            Section("GitHub") {
                TokenField(placeholder: "Paste a GitHub token (optional for public repos)", saved: $settings.githubToken) {
                    Task { await monitor.refresh() }
                }
                HStack {
                    Text("Fine-grained token with Actions: Read. Stored privately on this Mac.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use gh CLI token") {
                        if let t = GitHub.ghCLIToken() { settings.githubToken = t; ghMessage = "Imported from gh." }
                        else { ghMessage = "gh isn't installed or signed in (run: gh auth login)." }
                    }
                    .font(.caption)
                    Link("Create…", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!).font(.caption)
                }
                if let ghMessage { Text(ghMessage).font(.caption).foregroundStyle(.secondary) }
                HStack {
                    let count = settings.sources.filter { $0.provider == .github }.count
                    Text(count == 0 ? "No repositories watched yet." : "\(count) repositor\(count == 1 ? "y" : "ies") watched.")
                        .font(.callout).foregroundStyle(count == 0 ? Color.orange : .secondary)
                    Spacer()
                    Button("Choose repositories…") { showRepoPicker = true }
                        .disabled(settings.githubToken.isEmpty)
                }
            }

            Section("General") {
                Picker("Refresh every", selection: $settings.refreshSeconds) {
                    Text("15 seconds").tag(15)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("2 minutes").tag(120)
                    Text("5 minutes").tag(300)
                }
                Text("While a build is running BuildBar checks at least every 15 seconds.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Runs per source: \(settings.runsPerSource)", value: $settings.runsPerSource, in: 3...30)
                Toggle("Notify when a build finishes", isOn: $settings.notify)
                Toggle("Also notify on success", isOn: $settings.notifySuccess).disabled(!settings.notify)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        settings.launchAtLogin = on
                        launchAtLogin = settings.launchAtLogin
                    }
            }

            HStack {
                Spacer()
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                Button("Test connections") { Task { await monitor.refresh() } }
            }
        }
        .formStyle(.grouped)
        .textFieldStyle(.roundedBorder)
        .frame(width: 560)
        .frame(minHeight: 520)
        .onAppear { launchAtLogin = settings.launchAtLogin }
        .sheet(isPresented: $showRepoPicker) {
            RepoPicker(token: settings.githubToken, sources: $settings.sources) {
                showRepoPicker = false
                Task { await monitor.refresh() }
            }
        }
        .onDisappear { Task { await monitor.refresh() } }
    }

    private func addPasted() {
        guard let s = Source.from(urlString: pasted) else {
            pasteError = "That doesn't look like an Azure DevOps or GitHub URL."
            return
        }
        settings.sources.append(s)
        pasted = ""
        pasteError = nil
        Task { await monitor.refresh() }
    }
}

private struct SourceEditor: View {
    @Binding var source: Source
    let error: String?
    let onDelete: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Display name", text: $source.name, prompt: Text(source.displayName))
                switch source.provider {
                case .azure:
                    TextField("Organization", text: $source.organization, prompt: Text("organization"))
                    TextField("Project", text: $source.project, prompt: Text("project"))
                    TextField("Pipeline ids", text: $source.definitionIDs, prompt: Text("all pipelines (or e.g. 105, 112)"))
                case .github:
                    TextField("Owner", text: $source.owner, prompt: Text("owner"))
                    TextField("Repository", text: $source.repo, prompt: Text("repository"))
                    TextField("Workflow", text: $source.workflow, prompt: Text("all workflows (or e.g. ci.yml)"))
                }
                TextField("Branch", text: $source.branch, prompt: Text("all branches"))
                HStack {
                    Spacer()
                    Button("Remove", role: .destructive, action: onDelete)
                }
            }
            .padding(.top, 6)
        } label: {
            HStack(spacing: 8) {
                Toggle("", isOn: $source.enabled).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                Image(systemName: source.provider.symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(source.displayName)
                    Text(subtitle).font(.caption).foregroundStyle(error == nil ? Color.secondary : Color.orange)
                        .lineLimit(1)
                }
            }
        }
        .onAppear { if !source.isConfigured { expanded = true } }
    }

    private var subtitle: String {
        if let error { return error }
        switch source.provider {
        case .azure:
            let p = source.definitionIDs.isEmpty ? "all pipelines" : "pipeline \(source.definitionIDs)"
            return "Azure DevOps · \(source.organization) · \(p)"
        case .github:
            return "GitHub · \(source.workflow.isEmpty ? "all workflows" : source.workflow)"
        }
    }
}

/// A token box with an explicit Save button and a "saved" status line.
private struct TokenField: View {
    let placeholder: String
    @Binding var saved: String
    let onChange: () -> Void
    @State private var draft = ""
    @State private var flash = false

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SecureField("Token", text: $draft, prompt: Text(placeholder))
                    .labelsHidden()
                    .onSubmit(save)
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
            HStack(spacing: 8) {
                if saved.isEmpty {
                    Label("No token saved", systemImage: "key").foregroundStyle(.secondary)
                } else {
                    Label("Token saved (…\(saved.suffix(4)))", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                    if flash { Text("Saved").foregroundStyle(.green).transition(.opacity) }
                    Spacer()
                    Button("Remove token", role: .destructive) { saved = ""; onChange() }
                        .buttonStyle(.link).foregroundStyle(.red)
                }
            }
            .font(.caption)
        }
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        saved = trimmed
        draft = ""
        onChange()
        withAnimation { flash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { withAnimation { flash = false } }
    }
}

/// Lists the repositories the GitHub token can see; ticking one watches it.
private struct RepoPicker: View {
    let token: String
    @Binding var sources: [Source]
    let onDone: () -> Void
    @State private var repos: [GitHub.RepoInfo] = []
    @State private var error: String?
    @State private var loading = true
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose GitHub repositories").font(.headline)
            TextField("Filter", text: $filter, prompt: Text("Filter repositories"))
                .textFieldStyle(.roundedBorder)
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    Text(error).foregroundStyle(.red).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if repos.isEmpty {
                    Text("This token can't see any repositories. Check its Repository access.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(shown) { repo in
                        Toggle(isOn: binding(for: repo)) {
                            HStack {
                                Text(repo.full_name)
                                if repo.private { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                if let d = ISODate.parse(repo.pushed_at) {
                                    Text(Format.ago(d)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                    .listStyle(.bordered)
                }
            }
            .frame(height: 320)
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task {
            do { repos = try await GitHub.listRepos(token: token) } catch { self.error = error.localizedDescription }
            loading = false
        }
    }

    private var shown: [GitHub.RepoInfo] {
        let f = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return f.isEmpty ? repos : repos.filter { $0.full_name.lowercased().contains(f) }
    }

    private func binding(for repo: GitHub.RepoInfo) -> Binding<Bool> {
        let parts = repo.full_name.split(separator: "/").map(String.init)
        let owner = parts.first ?? "", name = parts.count > 1 ? parts[1] : ""
        let match: (Source) -> Bool = { $0.provider == .github && $0.owner.lowercased() == owner.lowercased() && $0.repo.lowercased() == name.lowercased() }
        return Binding(
            get: { sources.contains(where: match) },
            set: { on in
                if on {
                    if !sources.contains(where: match) {
                        var s = Source(provider: .github); s.owner = owner; s.repo = name
                        sources.append(s)
                    }
                } else {
                    sources.removeAll(where: match)
                }
            })
    }
}
