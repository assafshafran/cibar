import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if settings.sources.filter(\.enabled).isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(settings.sources.filter(\.enabled)) { source in
                            SourceSection(source: source, rows: rows(for: source), expanded: expandedBinding(source.id))
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: listHeight)
            }
            Divider()
            footer
        }
        .frame(width: 460)
        .onAppear {
            monitor.markSeen()
            Task { await monitor.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            monitor.markSeen()
        }
    }

    /// Running/queued runs always, then the newest ones up to the configured row count (all when expanded).
    private func rows(for source: Source) -> (shown: [BuildRun], hidden: Int) {
        let list = monitor.runs[source.id] ?? []
        if expanded.contains(source.id) { return (list, 0) }
        let active = list.filter { $0.state.isActive }
        let rest = list.filter { !$0.state.isActive }
        let shown = active + rest.prefix(max(0, settings.menuRows - active.count))
        let ids = Set(shown.map(\.id))
        return (list.filter { ids.contains($0.id) }, list.count - shown.count)
    }

    private func expandedBinding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    /// Content height, so the popover hugs the list; it only scrolls when it can't fit on screen.
    private var listHeight: CGFloat {
        var h: CGFloat = 8
        for s in settings.sources.filter(\.enabled) {
            h += 34
            if monitor.errors[s.id] != nil { h += 20 }
            let r = rows(for: s)
            h += r.shown.isEmpty ? 22 : CGFloat(r.shown.count) * 46
            if r.hidden > 0 || expanded.contains(s.id) { h += 22 }
        }
        let screen = (NSScreen.main?.visibleFrame.height ?? 900) - 120
        return min(max(h, 60), screen)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Builds").font(.headline)
            if monitor.anyActive {
                Text("running").font(.caption.weight(.medium)).foregroundStyle(.blue)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
            }
            Spacer()
            if monitor.isRefreshing { ProgressView().controlSize(.small) }
            iconButton("arrow.clockwise", help: "Refresh now") { Task { await monitor.refresh() } }
                .keyboardShortcut("r")
            iconButton("gearshape", help: "Settings") { openSettings() }
                .keyboardShortcut(",")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer").font(.largeTitle).foregroundStyle(.secondary)
            Text("Nothing to watch yet").font(.headline)
            Text("Add an Azure DevOps pipeline or a GitHub repository.")
                .font(.callout).foregroundStyle(.secondary)
            Button("Open Settings") { openSettings() }.buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity).padding(24)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            if let update = Updater.shared.available {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                    Text("CIBar \(update.version) is available").font(.caption.weight(.medium))
                    Spacer()
                    Button("Download") { Updater.shared.download() }
                        .buttonStyle(.link).font(.caption)
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color.blue.opacity(0.08))
                Divider()
            }
            footerRow
        }
    }

    private var footerRow: some View {
        HStack {
            TimelineView(.periodic(from: .now, by: 5)) { _ in
                Text(monitor.lastRefresh.map { "Updated \(Format.ago($0))" } ?? "Not refreshed yet")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain).font(.caption).foregroundStyle(.secondary)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
            .buttonStyle(.borderless).help(help)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate()
    }
}

private struct SourceSection: View {
    @Environment(Monitor.self) private var monitor
    let source: Source
    let rows: (shown: [BuildRun], hidden: Int)
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: source.provider.symbol).font(.caption).foregroundStyle(.secondary)
                Text(source.displayName).font(.subheadline.weight(.semibold))
                if !source.branch.isEmpty {
                    Text(source.branch).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if let url = source.webURL {
                    Button { NSWorkspace.shared.open(url) } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless).help("Open in \(source.provider.name)")
                }
            }
            .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)

            if let error = monitor.errors[source.id] {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .padding(.horizontal, 12).padding(.bottom, 4)
            }
            let list = monitor.runs[source.id] ?? []
            if list.isEmpty && monitor.errors[source.id] == nil {
                Text(monitor.lastRefresh == nil ? "Loading…" : "No runs")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.bottom, 6)
            }
            ForEach(rows.shown) { run in RunRow(run: run) }
            if rows.hidden > 0 || expanded {
                Button(expanded ? "Show less" : "Show \(rows.hidden) more") { expanded.toggle() }
                    .buttonStyle(.link).font(.caption)
                    .padding(.leading, 44).padding(.bottom, 4)
            }
        }
    }
}

private struct RunRow: View {
    let run: BuildRun
    @State private var hovering = false

    var body: some View {
        Button {
            if let url = run.url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(alignment: .center, spacing: 10) {
                StateIcon(state: run.state)
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 5) {
                        Text(run.number).monospacedDigit()
                        if let repo = run.repo, !repo.isEmpty { dot; Image(systemName: "shippingbox").imageScale(.small); Text(repo) }
                        if let branch = run.branch, !branch.isEmpty { dot; Image(systemName: "arrow.triangle.branch").imageScale(.small); Text(branch) }
                        if let author = run.author, !author.isEmpty { dot; Text(author) }
                    }
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(run.queued.map(Format.ago) ?? "").font(.caption)
                        Text(Format.duration(run)).font(.caption.monospacedDigit())
                            .foregroundStyle(run.state.isActive ? Color.blue : .secondary)
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.08) : .clear).padding(.horizontal, 4))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(run.state.label) · \(run.pipeline)\(run.commit.map { " · \($0)" } ?? "")")
    }

    private var dot: some View { Text("·") }
}

struct StateIcon: View {
    let state: BuildState
    var body: some View {
        Group {
            if state == .running {
                Image(systemName: state.symbol).symbolEffect(.rotate, options: .repeating)
            } else {
                Image(systemName: state.symbol)
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(Color(nsColor: state.color))
        .frame(width: 22)
    }
}

enum Format {
    static func ago(_ date: Date) -> String {
        let s = -date.timeIntervalSinceNow
        if s < 45 { return "just now" }
        if s < 3600 { return "\(Int(s / 60))m ago" }
        if s < 86400 { return "\(Int(s / 3600))h ago" }
        if s < 172_800 { return "yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func duration(_ run: BuildRun) -> String {
        if run.state == .queued { return "queued" }
        guard let start = run.started else { return "" }
        let end = run.finished ?? Date()
        let t = max(0, Int(end.timeIntervalSince(start)))
        if t >= 3600 { return String(format: "%dh %02dm", t / 3600, (t % 3600) / 60) }
        return String(format: "%dm %02ds", t / 60, t % 60)
    }
}
