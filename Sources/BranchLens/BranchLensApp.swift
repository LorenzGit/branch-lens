import AppKit
import SwiftUI

@main
struct BranchLensApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1100, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") {
                    NotificationCenter.default.post(name: .openRepository, object: nil)
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup(replacing: .appInfo) {
                Button("About BranchLens") {
                    showAboutPanel()
                }
            }
        }
    }

    private func showAboutPanel() {
        // Copyright comes from Info.plist (`NSHumanReadableCopyright`).
        // Don't also pass `.credits` with the same text or it appears twice.
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "BranchLens",
        ])
    }
}

extension Notification.Name {
    static let openRepository = Notification.Name("BranchLens.openRepository")
}
