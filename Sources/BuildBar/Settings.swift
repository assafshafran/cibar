import Foundation
import Observation
import Security
import ServiceManagement

enum Keychain {
    static let service = "BuildBar"

    static func get(_ account: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return "" }
        return String(decoding: d, as: UTF8.self)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
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

    var azureToken: String { didSet { Keychain.set(azureToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "azure-devops") } }
    var githubToken: String { didSet { Keychain.set(githubToken.trimmingCharacters(in: .whitespacesAndNewlines), for: "github") } }

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
        azureToken = Keychain.get("azure-devops")
        githubToken = Keychain.get("github")
    }

    private func saveSources() {
        if let data = try? JSONEncoder().encode(sources) {
            defaults.set(String(decoding: data, as: UTF8.self), forKey: "sources")
        }
    }
}
