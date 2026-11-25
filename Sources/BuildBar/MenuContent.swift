import AppKit
import SwiftUI

struct MenuContent: View {
    @Environment(Monitor.self) private var monitor
    @Environment(AppSettings.self) private var settings
    @Environment(\.openWindow) private var openWindow

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
                            SourceSection(source: source)
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

    /// Rough content height so the popover hugs short lists and scrolls long ones.
    private var listHeight: CGFloat {
        let sources = settings.sources.filter(\.enabled)
        var h: CGFloat = 8
        for s in sources {
            h += 34
            if monitor.errors[s.id] != nil { h += 20 }
            let n = monitor.runs[s.id]?.count ?? 0
            h += n == 0 ? 22 : CGFloat(n) * 46
        }
        return min(max(h, 60), 560)
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
            ForEach(list) { run in RunRow(run: run) }
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
