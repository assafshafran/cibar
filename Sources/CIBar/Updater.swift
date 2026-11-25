import AppKit
import Foundation
import Observation
import UserNotifications

/// Checks GitHub for a newer CIBar release: once a day when automatic checks are on, and on demand.
/// It only tells the person; the download is the notarised disk image attached to the release.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let repo = "cibar-dev/cibar"

    struct Release: Equatable {
        let version: String
        let page: URL
        let download: URL
    }

    private(set) var available: Release?
    private(set) var checking = false
    private(set) var lastChecked: Date?
    private(set) var lastError: String?

    private let defaults = UserDefaults.standard
    private var timer: Timer?

    var automatic: Bool {
        get { defaults.object(forKey: "checkUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkUpdates"); schedule() }
    }

    /// The running app's version ("0" when run outside a bundle, e.g. `swift run`).
    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    func start() {
        schedule()
        if automatic { Task { await check() } }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automatic else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 24 * 3600, repeats: true) { _ in
            Task { @MainActor in await Updater.shared.check() }
        }
    }

    func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false; lastChecked = Date() }
        struct Asset: Decodable { let name: String; let browser_download_url: String }
        struct Latest: Decodable { let tag_name: String; let html_url: String; let assets: [Asset]; let draft: Bool?; let prerelease: Bool? }

        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CIBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await Providers.session.data(for: req)
            switch (resp as? HTTPURLResponse)?.statusCode ?? 0 {
            case 200: break
            case 404: lastError = nil; available = nil; return   // no release published yet
            case let code: throw ProviderError("GitHub returned HTTP \(code)")
            }
            let latest = try JSONDecoder().decode(Latest.self, from: data)
            let version = latest.tag_name.hasPrefix("v") ? String(latest.tag_name.dropFirst()) : latest.tag_name
            lastError = nil
            guard Self.isNewer(version, than: currentVersion), latest.draft != true, latest.prerelease != true,
                  let page = URL(string: latest.html_url) else { available = nil; return }
            let dmg = latest.assets.first { $0.name.hasSuffix(".dmg") }.flatMap { URL(string: $0.browser_download_url) }
            let release = Release(version: version, page: page, download: dmg ?? page)
            available = release
            notifyOnce(release)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func download() {
        if let r = available { NSWorkspace.shared.open(r.download) }
    }

    /// One notification per new version, however many times it's seen.
    private func notifyOnce(_ release: Release) {
        guard defaults.string(forKey: "notifiedVersion") != release.version else { return }
        defaults.set(release.version, forKey: "notifiedVersion")
        let content = UNMutableNotificationContent()
        content.title = "CIBar \(release.version) is available"
        content.body = "You have \(currentVersion). Click to download the update."
        content.userInfo = ["url": release.download.absoluteString]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "update-\(release.version)", content: content, trigger: nil))
    }

    /// Numeric comparison of dotted versions: 1.10.0 > 1.9.2.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
