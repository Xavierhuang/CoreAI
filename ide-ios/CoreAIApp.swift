import SwiftUI

// Entry point for the iPhone app. SwiftUI WindowGroup wraps the chat view
// inside a NavigationStack. The Mac app's File menu / multi-window machinery
// doesn't apply on iPhone — it's a single chat screen.
@main
struct CoreAIApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ChatScreen()
            }
        }
    }
}
