import SwiftUI

struct ContentView: View {
    @EnvironmentObject var store: YegenStore
    @EnvironmentObject var appearance: AppearanceStore
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
        // Aparência (v1.2): tema e densidade valem pro app inteiro. Trocar o
        // tema reconstrói a árvore (`.id`) pra todos os tokens de `Theme`
        // relerem a paleta nova; o Dynamic Type acompanha a densidade
        // (Confortável = .medium, Compacto = .small — um degrau abaixo do
        // padrão do sistema, como o app sempre foi).
        .id(appearance.theme.rawValue + "|" + appearance.density.rawValue)
        .environment(\.dynamicTypeSize, appearance.density.dynamicTypeSize)
        .preferredColorScheme(appearance.theme.isLight ? .light : .dark)
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
    /// Quando presente, mostra o botão "Concluir" na barra do teclado.
    var onKeyboardDismiss: (() -> Void)? = nil
    @EnvironmentObject var appearance: AppearanceStore
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: appearance.density.stackSpacing) { content() }
                    .padding(appearance.density.stackSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if let onKeyboardDismiss {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Concluir", action: onKeyboardDismiss)
                            .font(.body.weight(.semibold))
                            .foregroundColor(Theme.gold)
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
