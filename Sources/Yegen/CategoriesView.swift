import SwiftUI

/// Aba Categorias: o grupo de links detectado na página de lista vira as
/// abas (pages) da rule. Marcar/desmarcar é escolha dele.
struct CategoriesView: View {
    @EnvironmentObject var store: YegenStore

    var body: some View {
        NavigationStack {
            Group {
                if store.categories.isEmpty {
                    ScrollView {
                        EmptyAnalysisView(text: "Nenhum grupo de categorias detectado.\nO grupo certo é o de links de menu/categorias da página de lista — os links dos próprios itens nunca viram categorias.")
                    }
                } else {
                    List {
                        Section {
                            ForEach($store.categories) { $cat in
                                Toggle(isOn: $cat.selected) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text($cat.wrappedValue.name)
                                            .font(.callout)
                                            .foregroundColor(Theme.textPrimary)
                                        Text(store.pagination.paginate($cat.wrappedValue.url))
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(Theme.textDim)
                                            .lineLimit(2)
                                    }
                                }
                                .toggleStyle(SwitchToggleStyle(tint: Theme.gold))
                                .listRowBackground(Theme.panel)
                            }
                        } header: {
                            Text("\(store.categories.filter { $0.selected }.count) de \(store.categories.count) marcadas — viram abas (pages) na rule, depois do Início")
                                .foregroundColor(Theme.textDim)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Categorias")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { store.ensureAnalyzed() }
    }
}
