import SwiftUI

@main
struct YegenApp: App {
    @StateObject private var store = YegenStore()
    @StateObject private var appearance = AppearanceStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(appearance)
            // O esquema claro/escuro acompanha o tema (ContentView aplica
            // .preferredColorScheme conforme a aparência escolhida).
        }
    }
}
