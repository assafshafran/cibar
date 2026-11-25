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
        let worst = unseen.max { $0.state.severity < $1.state.severity }?.state
        if anyActive { return Icons.running(frame: spinnerFrame, badge: worst?.color) }
        if let worst { return Icons.result(worst) }
        if runs.isEmpty && !errors.isEmpty { return Icons.warning }
        if settings.sources.isEmpty { return Icons.idle(nil, empty: true) }
        return Icons.idle(latest?.state)
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
            spinner = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
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
    /// Frames in one cycle of the "running" animation (a pulse travelling along the pipeline).
    static let spinnerFrames = 9
    private static var cache: [String: NSImage] = [:]

    /// Menu bar glyph: three pipeline stages joined by a line. The last stage carries the result.
    static func idle(_ last: BuildState?, empty: Bool = false) -> NSImage {
        cached("i:\(last?.rawValue ?? "-"):\(empty)") {
            pipeline(tint: .black, progress: empty ? 0 : 3, end: last.flatMap(endMark), template: true)
        }
    }

    static func result(_ state: BuildState) -> NSImage {
        cached("r:\(state.rawValue)") { pipeline(tint: state.color, progress: 3, end: endMark(state) ?? .check) }
    }

    static func running(frame: Int, badge: NSColor?) -> NSImage {
        cached("s:\(frame):\(badge?.description ?? "-")") {
            pipeline(tint: .systemBlue, progress: frame / 3, pulse: CGFloat(frame % 3) / 2, dot: badge)
        }
    }

    static var warning: NSImage {
        cached("w") { pipeline(tint: .black, progress: 3, end: .bang, template: true) }
    }

    enum Mark { case check, cross, bang, stop }

    private static func endMark(_ s: BuildState) -> Mark? {
        switch s {
        case .succeeded: .check
        case .failed: .cross
        case .partial: .bang
        case .canceled: .stop
        default: nil
        }
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let img = cache[key] { return img }
        let img = make()
        cache[key] = img
        return img
    }

    /// - progress: stages already done (filled); the stage at `progress` pulses while running.
    private static func pipeline(tint: NSColor, progress: Int, pulse: CGFloat = 0, end: Mark? = nil,
                                 template: Bool = false, dot: NSColor? = nil) -> NSImage {
        let img = NSImage(size: NSSize(width: 30, height: 18), flipped: false) { _ in
            draw(in: CGRect(x: 0, y: 0, width: 30, height: 18), tint: tint, progress: progress,
                 pulse: pulse, end: end, dot: dot)
            return true
        }
        img.isTemplate = template
        return img
    }

    /// Draws the pipeline glyph scaled into `rect` (designed on a 30x18 grid).
    static func draw(in rect: CGRect, tint: NSColor, progress: Int, pulse: CGFloat = 0, end: Mark? = nil,
                     dot: NSColor? = nil, cutout: NSColor? = nil) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        ctx.scaleBy(x: rect.width / 30, y: rect.height / 18)
        let xs: [CGFloat] = [3.6, 12.6, 23.8]
        let y: CGFloat = 9
        let r: CGFloat = 2.5
        let endR: CGFloat = end == nil ? r : 5.3
        tint.setStroke(); tint.setFill()

        // Connectors
        for i in 0..<2 {
            let a = xs[i] + r + 1.4
            let b = xs[i + 1] - (i == 1 ? endR : r) - 1.4
            let line = NSBezierPath()
            line.move(to: CGPoint(x: a, y: y)); line.line(to: CGPoint(x: b, y: y))
            line.lineWidth = 1.5; line.lineCapStyle = .round
            if i >= progress { tint.withAlphaComponent(0.45).setStroke() } else { tint.setStroke() }
            line.stroke()
        }
        // Stages
        for i in 0..<3 {
            let isEnd = i == 2 && end != nil
            let rr = isEnd ? endR : (i == progress ? r + 0.9 * pulse : r)
            let oval = NSBezierPath(ovalIn: CGRect(x: xs[i] - rr, y: y - rr, width: rr * 2, height: rr * 2))
            if isEnd || i < progress || i == progress && pulse > 0 {
                tint.setFill(); oval.fill()
            } else {
                tint.setStroke(); oval.lineWidth = 1.3
                let inner = NSBezierPath(ovalIn: CGRect(x: xs[i] - rr + 0.65, y: y - rr + 0.65,
                                                        width: rr * 2 - 1.3, height: rr * 2 - 1.3))
                inner.lineWidth = 1.3; inner.stroke()
            }
        }
        // Result mark knocked out of the last stage
        if let end {
            let cx = xs[2]
            let mark = NSBezierPath()
            mark.lineWidth = 1.7; mark.lineCapStyle = .round; mark.lineJoinStyle = .round
            switch end {
            case .check:
                mark.move(to: CGPoint(x: cx - 2.5, y: y + 0.1))
                mark.line(to: CGPoint(x: cx - 0.7, y: y - 1.9))
                mark.line(to: CGPoint(x: cx + 2.6, y: y + 2.1))
            case .cross:
                mark.move(to: CGPoint(x: cx - 1.9, y: y - 1.9)); mark.line(to: CGPoint(x: cx + 1.9, y: y + 1.9))
                mark.move(to: CGPoint(x: cx - 1.9, y: y + 1.9)); mark.line(to: CGPoint(x: cx + 1.9, y: y - 1.9))
            case .bang:
                mark.move(to: CGPoint(x: cx, y: y + 2.6)); mark.line(to: CGPoint(x: cx, y: y - 0.2))
                mark.move(to: CGPoint(x: cx, y: y - 2.3)); mark.line(to: CGPoint(x: cx, y: y - 2.35))
            case .stop:
                mark.move(to: CGPoint(x: cx - 2.2, y: y)); mark.line(to: CGPoint(x: cx + 2.2, y: y))
            }
            if let cutout {
                cutout.setStroke(); mark.stroke()
            } else {
                ctx.setBlendMode(.clear); mark.stroke(); ctx.setBlendMode(.normal)
            }
        }
        if let dot {
            let d = CGRect(x: 24.2, y: 12.2, width: 5.6, height: 5.6)
            ctx.setBlendMode(.clear); NSBezierPath(ovalIn: d.insetBy(dx: -1.2, dy: -1.2)).fill(); ctx.setBlendMode(.normal)
            dot.setFill(); NSBezierPath(ovalIn: d).fill()
        }
        ctx.restoreGState()
    }

    /// The app icon (Finder, notifications): the same glyph, white on a blue squircle.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset = rect.insetBy(dx: size * 0.09, dy: size * 0.09)
            let bg = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
            NSGradient(starting: NSColor(red: 0.20, green: 0.48, blue: 0.98, alpha: 1),
                       ending: NSColor(red: 0.07, green: 0.20, blue: 0.62, alpha: 1))?.draw(in: bg, angle: -90)
            let w = inset.width * 0.8
            let h = w * 18 / 30
            let glyph = CGRect(x: inset.midX - w / 2, y: inset.midY - h / 2, width: w, height: h)
            draw(in: glyph, tint: .white, progress: 3, end: .check,
                 cutout: NSColor(red: 0.13, green: 0.34, blue: 0.80, alpha: 1))
            return true
        }
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
