import SwiftUI

@main
struct YegenApp: App {
    @StateObject private var store = YegenStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
        }
    }
}
