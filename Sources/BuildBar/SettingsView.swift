import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @State private var pasted = ""
    @State private var pasteError: String?
    @State private var ghMessage: String?
    @State private var launchAtLogin = false

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
                SecureField("Personal access token", text: $settings.azureToken, prompt: Text("Paste your Azure DevOps token here"))
                HStack {
                    Text("Scope needed: Build (Read). Stored in your Keychain.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let org = settings.sources.first(where: { $0.provider == .azure && !$0.organization.isEmpty })?.organization,
                       let url = URL(string: "https://dev.azure.com/\(org)/_usersSettings/tokens") {
                        Link("Create a token…", destination: url).font(.caption)
                    }
                }
            }

            Section("GitHub") {
                SecureField("Token", text: $settings.githubToken, prompt: Text("Paste a GitHub token (optional for public repos)"))
                HStack {
                    Text("Fine-grained token with Actions: Read. Stored in your Keychain.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use gh CLI token") {
                        if let t = GitHub.ghCLIToken() { settings.githubToken = t; ghMessage = "Imported from gh." }
                        else { ghMessage = "gh isn't installed or signed in (run: gh auth login)." }
                    }
                    .font(.caption)
                    Link("Create…", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!).font(.caption)
                }
                if let ghMessage { Text(ghMessage).font(.caption).foregroundStyle(.secondary) }
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
