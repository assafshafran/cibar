import AppKit
import Foundation
import Observation
import UserNotifications

/// Polls every enabled source, keeps the latest runs, and notices when a build finishes.
@MainActor
@Observable
final class Monitor {
    static let shared = Monitor(settings: .shared)

    let settings: AppSettings
    private(set) var runs: [UUID: [BuildRun]] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false
    /// Builds that finished since the user last opened the menu.
    private(set) var unseen: [BuildRun] = []
    private(set) var spinnerFrame = 0

    private var known: [String: BuildState] = [:]
    private var primed: Set<UUID> = []
    private var loop: Task<Void, Never>?
    private var spinner: Timer?

    init(settings: AppSettings) { self.settings = settings }

    var anyActive: Bool { runs.values.contains { $0.contains { $0.state.isActive } } }

    /// The most recently queued run across all sources.
    var latest: BuildRun? { runs.values.flatMap { $0 }.max { $0.sortDate < $1.sortDate } }

    var icon: NSImage {
        let badge = unseen.max { $0.state.severity < $1.state.severity }?.state.color
        if anyActive { return Icons.spinner(frame: spinnerFrame, badge: badge) }
        if let worst = unseen.max(by: { $0.state.severity < $1.state.severity }) { return Icons.result(worst.state) }
        if runs.isEmpty && !errors.isEmpty { return Icons.template("exclamationmark.triangle") }
        if settings.sources.isEmpty { return Icons.template("hammer") }
        switch latest?.state {
        case .failed?: return Icons.template("xmark.circle")
        case .partial?: return Icons.template("exclamationmark.circle")
        case .succeeded?: return Icons.template("checkmark.circle")
        default: return Icons.template("circle.dashed")
        }
    }

    func start() {
        guard loop == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refresh() } }

        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                let base = Double(self.settings.refreshSeconds)
                let wait = self.anyActive ? min(base, 15) : base
                try? await Task.sleep(for: .seconds(wait))
            }
        }
    }

    func markSeen() { if !unseen.isEmpty { unseen = [] } }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let sources = settings.sources.filter(\.enabled)
        let az = settings.azureToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let gh = settings.githubToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let top = max(1, min(settings.runsPerSource, 30))

        let results = await withTaskGroup(of: (Source, Result<[BuildRun], Error>).self) { group in
            for s in sources {
                group.addTask {
                    do { return (s, .success(try await Providers.fetch(s, azureToken: az, githubToken: gh, top: top))) }
                    catch { return (s, .failure(error)) }
                }
            }
            var all: [(Source, Result<[BuildRun], Error>)] = []
            for await r in group { all.append(r) }
            return all
        }

        var finished: [BuildRun] = []
        for (source, result) in results {
            switch result {
            case .success(let list):
                if primed.contains(source.id) {
                    for run in list where run.state.isFinished {
                        let prev = known[run.id]
                        let wasActive = prev?.isActive ?? false
                        // A run we never saw running but that finished just now (a fast build between polls).
                        let newAndRecent = prev == nil && (run.finished.map { -$0.timeIntervalSinceNow < 600 } ?? false)
                        if wasActive || newAndRecent { finished.append(run) }
                    }
                }
                for run in list { known[run.id] = run.state }
                primed.insert(source.id)
                runs[source.id] = list
                errors[source.id] = nil
            case .failure(let error):
                if (error as? URLError)?.code == .cancelled { continue }
                errors[source.id] = error.localizedDescription
            }
        }

        // Forget sources that were removed or disabled.
        let live = Set(sources.map(\.id))
        for id in runs.keys where !live.contains(id) { runs[id] = nil }
        for id in errors.keys where !live.contains(id) { errors[id] = nil }
        primed.formIntersection(live)

        if !finished.isEmpty {
            unseen.append(contentsOf: finished)
            notify(finished)
        }
        lastRefresh = Date()
        updateSpinner()
    }

    private func updateSpinner() {
        if anyActive, spinner == nil {
            spinner = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.spinnerFrame = ((self?.spinnerFrame ?? 0) + 1) % Icons.spinnerFrames }
            }
        } else if !anyActive, let t = spinner {
            t.invalidate()
            spinner = nil
        }
    }

    private func notify(_ finished: [BuildRun]) {
        guard settings.notify else { return }
        let names = Dictionary(settings.sources.map { ($0.id, $0.displayName) }, uniquingKeysWith: { a, _ in a })
        for run in finished.prefix(4) {
            if run.state == .succeeded && !settings.notifySuccess { continue }
            let content = UNMutableNotificationContent()
            let emoji = switch run.state {
            case .succeeded: "✅"
            case .failed: "❌"
            case .partial: "⚠️"
            default: "⏹"
            }
            content.title = "\(emoji) \(names[run.sourceID] ?? run.pipeline): \(run.state.label)"
            content.subtitle = run.number + (run.branch.map { " · \($0)" } ?? "")
            content.body = run.title
            if run.state == .failed { content.sound = .default }
            if let url = run.url { content.userInfo = ["url": url.absoluteString] }
            let req = UNNotificationRequest(identifier: run.id, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req)
        }
    }
}

enum Icons {
    static let spinnerFrames = 12
    private static var cache: [String: NSImage] = [:]

    static func template(_ symbol: String) -> NSImage {
        cached("t:\(symbol)") { render(symbol, color: nil) }
    }

    static func result(_ state: BuildState) -> NSImage {
        cached("r:\(state.rawValue)") { render(state.symbol, color: state.color) }
    }

    static func spinner(frame: Int, badge: NSColor?) -> NSImage {
        let key = "s:\(frame):\(badge?.description ?? "-")"
        return cached(key) {
            render("arrow.triangle.2.circlepath", color: .systemBlue,
                   rotation: CGFloat(frame) / CGFloat(spinnerFrames) * 2 * .pi, dot: badge)
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let img = cache[key] { return img }
        let img = make()
        cache[key] = img
        return img
    }

    private static func render(_ symbol: String, color: NSColor?, rotation: CGFloat = 0, dot: NSColor? = nil) -> NSImage {
        var cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        if let color { cfg = cfg.applying(NSImage.SymbolConfiguration(paletteColors: [color])) }
        guard let sym = NSImage(systemSymbolName: symbol, accessibilityDescription: "Build status")?
            .withSymbolConfiguration(cfg) else { return NSImage() }
        let size = NSSize(width: 20, height: 18)
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.saveGState()
            ctx.translateBy(x: rect.midX, y: rect.midY)
            ctx.rotate(by: -rotation)
            let s = sym.size
            sym.draw(in: NSRect(x: -s.width / 2, y: -s.height / 2, width: s.width, height: s.height))
            ctx.restoreGState()
            if let dot {
                let r = NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)
                NSColor.white.setFill(); NSBezierPath(ovalIn: r.insetBy(dx: -1, dy: -1)).fill()
                dot.setFill(); NSBezierPath(ovalIn: r).fill()
            }
            return true
        }
        img.isTemplate = color == nil && dot == nil
        return img
    }
}

/// Shows banners while the app is frontmost and opens the run when one is clicked.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo["url"] as? String, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
