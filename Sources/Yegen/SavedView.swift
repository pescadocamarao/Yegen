import SwiftUI
import UniformTypeIdentifiers

/// Aba Salvos: testes guardados com persistência durável (Documents +
/// iCloud) e os botões de exportar/importar o arquivo de dados.
struct SavedView: View {
    @EnvironmentObject var store: YegenStore
    @State private var exportItem: ExportItem?
    @State private var showImporter = false
    @State private var pendingImport: Data?
    @State private var showImportChoice = false
    @State private var importError = false

    var body: some View {
        NavigationStack {
            Group {
                if store.savedTests.isEmpty {
                    ScrollView {
                        VStack(spacing: 14) {
                            locationNote
                            EmptyAnalysisView(text: "Nenhum teste salvo.\nMonte um teste na aba Entradas e toque em Salvar teste.")
                        }
                        .padding(.top, 8)
                    }
                } else {
                    List {
                        Section {
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
                        } header: {
                            Text("Testes salvos (\(store.savedTests.count))")
                        } footer: {
                            Text(store.savedLocationDescription)
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background)
            .navigationTitle("Salvos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        exportSaved()
                    } label: {
                        Label("Exportar", systemImage: "square.and.arrow.up")
                    }
                    .disabled(store.savedTests.isEmpty)
                    Button {
                        showImporter = true
                    } label: {
                        Label("Importar", systemImage: "square.and.arrow.down")
                    }
                }
            }
            .sheet(item: $exportItem) { item in
                ShareSheet(items: [item.url])
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.json]) { result in
                handleImportSelection(result)
            }
            .confirmationDialog("Importar testes salvos",
                                isPresented: $showImportChoice,
                                titleVisibility: .visible) {
                Button("Mesclar com os atuais") { applyImport(mode: .merge) }
                Button("Substituir tudo", role: .destructive) { applyImport(mode: .replace) }
                Button("Cancelar", role: .cancel) { pendingImport = nil }
            } message: {
                Text("Mesclar mantém os testes atuais e adiciona os novos. "
                     + "Substituir apaga os atuais e fica só com os do arquivo.")
            }
            .alert("Arquivo inválido", isPresented: $importError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Esse arquivo não é um JSON de Salvos do Yegen. Nada foi alterado.")
            }
        }
    }

    private var locationNote: some View {
        Text(store.savedLocationDescription)
            .font(.footnote)
            .foregroundColor(Theme.textDim)
            .padding(.horizontal)
    }

    // MARK: - Exportar / importar

    /// Exporta o próprio arquivo de dados (mesmo formato da persistência)
    /// e abre a folha de compartilhamento do sistema.
    private func exportSaved() {
        guard let data = store.exportSavedData() else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yegen-salvos.json")
        if (try? data.write(to: url, options: .atomic)) != nil {
            exportItem = ExportItem(url: url)
        }
    }

    private func handleImportSelection(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url),
              YegenDataStore.decodeTests(from: data) != nil else {
            importError = true
            return
        }
        pendingImport = data
        showImportChoice = true
    }

    private func applyImport(mode: YegenStore.ImportMode) {
        guard let data = pendingImport else { return }
        pendingImport = nil
        if store.importSavedData(data, mode: mode) == nil {
            importError = true
        }
    }
}

/// Folha de compartilhamento do sistema (UIActivityViewController).
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Item da folha de exportação (arquivo temporário com os Salvos).
struct ExportItem: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
