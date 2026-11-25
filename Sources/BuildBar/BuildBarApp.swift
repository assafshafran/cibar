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
        if args.contains("--dump") || args.contains("--snapshot") {
            Task { @MainActor in await Self.diagnose(args) }
            return
        }
        UNUserNotificationCenter.current().delegate = notificationDelegate
        Task { @MainActor in Monitor.shared.start() }
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
