import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: YegenStore
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            InputsView()
                .tabItem { Label("Entradas", systemImage: "square.and.pencil") }
                .tag(0)
            ListTabView()
                .tabItem { Label("Lista", systemImage: "list.bullet") }
                .tag(1)
            DetailTabView()
                .tabItem { Label("Detalhe", systemImage: "doc.text.magnifyingglass") }
                .tag(2)
            CategoriesView()
                .tabItem { Label("Categorias", systemImage: "folder") }
                .tag(3)
            JSONTabView()
                .tabItem { Label("JSON", systemImage: "curlybraces") }
                .tag(4)
            SavedView()
                .tabItem { Label("Salvos", systemImage: "tray.full") }
                .tag(5)
            GuideView()
                .tabItem { Label("Guia", systemImage: "book") }
                .tag(6)
        }
        .accentColor(Theme.gold)
        .background(Theme.background)
    }
}

/// Estado vazio das abas de análise.
struct EmptyAnalysisView: View {
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.largeTitle)
                .foregroundColor(Theme.textDim)
            Text(text)
                .font(.callout)
                .foregroundColor(Theme.textDim)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .panelCard()
        .padding()
    }
}

/// Fundo padrão das abas com rolagem.
struct TabScroll<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content() }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
