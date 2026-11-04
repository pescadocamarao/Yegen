import SwiftUI

/// Aba Salvos: testes guardados no aparelho (Documents/yegen-salvos.json).
struct SavedView: View {
    @EnvironmentObject var store: YegenStore

    var body: some View {
        NavigationStack {
            Group {
                if store.savedTests.isEmpty {
                    ScrollView {
                        EmptyAnalysisView(text: "Nenhum teste salvo.\nMonte um teste na aba Entradas e toque em Salvar teste.")
                    }
                } else {
                    List {
                        ForEach(store.savedTests) { test in
                            Button {
                                store.load(test)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(test.name)
                                        .font(.callout.weight(.semibold))
                                        .foregroundColor(Theme.textPrimary)
                                    Text(test.dateLabel)
                                        .font(.caption)
                                        .foregroundColor(Theme.textDim)
                                    let domain = Engine.siteOrigin(test.inputs)
                                    if !domain.isEmpty {
                                        Text(domain)
                                            .font(.system(.caption2, design: .monospaced))
                                            .foregroundColor(Theme.textDim)
                                    }
                                }
                            }
                            .listRowBackground(Theme.panel)
                        }
                        .onDelete { store.deleteTests(at: $0) }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Salvos")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
