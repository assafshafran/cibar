import AppKit
import SwiftUI
import UserNotifications

@main
struct BuildBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    private let monitor = Monitor.shared
    private let settings = AppSettings.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(monitor)
                .environment(settings)
        } label: {
            Image(nsImage: monitor.icon)
        }
        .menuBarExtraStyle(.window)

        Window("BuildBar Settings", id: "settings") {
            SettingsView()
                .environment(monitor)
                .environment(settings)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let notificationDelegate = NotificationDelegate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--render-icon"), i + 1 < args.count {
            Self.writePNG(Icons.appIcon(size: 1024), size: 1024, to: args[i + 1])
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-glyphs"), i + 1 < args.count {
            Task { @MainActor in Self.renderGlyphs(to: args[i + 1]); exit(0) }
            return
        }
        if args.contains("--dump") || args.contains("--snapshot") {
            Task { @MainActor in await Self.diagnose(args) }
            return
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { @MainActor in Monitor.shared.start() }
    }

    static func writePNG(_ image: NSImage, size: Int, to path: String) {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = NSSize(width: size, height: size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// Contact sheet of every menu bar state, on light and dark bars (for design review).
    @MainActor
    static func renderGlyphs(to path: String) {
        let states: [(String, NSImage)] = [
            ("idle ok", Icons.idle(.succeeded)), ("idle failed", Icons.idle(.failed)),
            ("running", Icons.running(frame: 1, badge: nil)), ("running", Icons.running(frame: 4, badge: nil)),
            ("running+fail", Icons.running(frame: 7, badge: .systemRed)),
            ("done ok", Icons.result(.succeeded)), ("done failed", Icons.result(.failed)),
            ("partial", Icons.result(.partial)), ("error", Icons.warning),
        ]
        let scale: CGFloat = 4, cell: CGFloat = 30 * scale, pad: CGFloat = 20
        let w = CGFloat(states.count) * (cell + pad) + pad, h = 2 * (18 * scale + pad) + pad
        let sheet = NSImage(size: NSSize(width: w, height: h), flipped: false) { _ in
            for (row, dark) in [true, false].enumerated() {
                let y = pad + CGFloat(row) * (18 * scale + pad)
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.93, alpha: 1)).setFill()
                NSRect(x: 0, y: y - pad / 2, width: w, height: 18 * scale + pad).fill()
                for (i, (_, img)) in states.enumerated() {
                    let r = NSRect(x: pad + CGFloat(i) * (cell + pad), y: y, width: cell, height: 18 * scale)
                    if img.isTemplate {
                        let tinted = NSImage(size: img.size, flipped: false) { rect in
                            img.draw(in: rect); (dark ? NSColor.white : NSColor.black).set()
                            rect.fill(using: .sourceAtop); return true
                        }
                        tinted.draw(in: r)
                    } else { img.draw(in: r) }
                }
            }
            return true
        }
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    /// `BuildBar --dump` prints what each source returns; `--snapshot <file.png>` renders the popover.
    @MainActor
    private static func diagnose(_ args: [String]) async {
        let monitor = Monitor.shared
        await monitor.refresh()
        for source in AppSettings.shared.sources where source.enabled {
            print("== \(source.displayName) [\(source.provider.name)]")
            if let e = monitor.errors[source.id] { print("   error: \(e)") }
            for r in monitor.runs[source.id] ?? [] {
                print("   \(r.state.label.padding(toLength: 10, withPad: " ", startingAt: 0)) \(r.number)  \(r.title.prefix(60))  [\(r.branch ?? "-")] \(Format.duration(r))")
            }
        }
        if let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count {
            let view = MenuContent()
                .environment(monitor).environment(AppSettings.shared)
                .background(Color(nsColor: .windowBackgroundColor))
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: args[i + 1]))
                print("snapshot: \(args[i + 1])")
            }
        }
        exit(0)
    }
}
