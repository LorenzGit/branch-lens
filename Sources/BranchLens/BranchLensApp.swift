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
        }
    }
}

extension Notification.Name {
    static let openRepository = Notification.Name("BranchLens.openRepository")
}
