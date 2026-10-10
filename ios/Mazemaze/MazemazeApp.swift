import SwiftUI

@main
struct MazemazeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    // mazemaze://paste only opens the paste screen (no text travels in the URL; the person pastes it).
                    if url.scheme?.lowercased() == "mazemaze", url.host?.lowercased() == "paste", url.query == nil { model.openPaste() }
                }
        }
    }
}
