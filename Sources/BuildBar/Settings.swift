import Foundation
import Observation
import ServiceManagement

/// Tokens live in ~/Library/Application Support/BuildBar/tokens.json, readable only by the user (0600),
/// the same way the gh and az CLIs keep theirs. (The login Keychain kept prompting for locally built apps.)
enum TokenStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BuildBar", isDirectory: true)
        return dir.appendingPathComponent("tokens.json")
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return dict
    }

    static func get(_ account: String) -> String { load()[account] ?? "" }

    static func set(_ value: String, for account: String) {
        var dict = load()
        dict[account] = value.isEmpty ? nil : value
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(dict) else { return }
        try? data.write(to: url, options: [.atomic])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    /// Stored as a JSON string so it can also be seeded with `defaults write`.
    var sources: [Source] { didSet { saveSources() } }
    var refreshSeconds: Int { didSet { defaults.set(refreshSeconds, forKey: "refreshSeconds") } }
    var runsPerSource: Int { didSet { defaults.set(runsPerSource, forKey: "runsPerSource") } }
    var notify: Bool { didSet { defaults.set(notify, forKey: "notify") } }
    var notifySuccess: Bool { didSet { defaults.set(notifySuccess, forKey: "notifySuccess") } }

    var azureToken: String { didSet { TokenStore.set(azureToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "azure-devops") } }
    var githubToken: String { didSet { TokenStore.set(githubToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "github") } }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do { newValue ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() } catch {
                NSLog("BuildBar: launch at login failed: \(error)")
            }
        }
    }

    private init() {
        if let json = defaults.string(forKey: "sources"),
           let decoded = try? JSONDecoder().decode([Source].self, from: Data(json.utf8)) {
            sources = decoded
        } else {
            sources = []
        }
        refreshSeconds = defaults.object(forKey: "refreshSeconds") as? Int ?? 30
        runsPerSource = defaults.object(forKey: "runsPerSource") as? Int ?? 8
        notify = defaults.object(forKey: "notify") as? Bool ?? true
        notifySuccess = defaults.object(forKey: "notifySuccess") as? Bool ?? true
        azureToken = TokenStore.get("azure-devops")
        githubToken = TokenStore.get("github")
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: "sources")
        }
    }
}
