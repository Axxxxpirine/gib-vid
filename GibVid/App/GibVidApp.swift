import SwiftUI

@main
struct GibVidApp: App {
    @State private var model = DownloadModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .task { model.launch() }
                .onOpenURL { model.handle(url: $0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active {
                        Task { await model.refreshClipboard() }
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                    Task { await model.refreshClipboard() }
                }
        }
    }
}
