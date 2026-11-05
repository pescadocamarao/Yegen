import SwiftUI
import UIKit

/// Aba Entradas: URLs, os três HTMLs colados e as ações Analisar / Salvar.
struct InputsView: View {
    @EnvironmentObject var store: YegenStore
    @State private var showSaveAlert = false
    @State private var saveName = ""
    @FocusState private var focusedField: FocusField?

    /// Campos e editores que podem receber o teclado nesta aba.
    enum FocusField: Hashable {
        case ruleName, siteUrl, indexUrl, searchUrl
        case listHTML, detailHTML, videoHTML
    }

    var body: some View {
        TabScroll(title: "Entradas", onKeyboardDismiss: { focusedField = nil }) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Yegen nativo v1.0.4")
                    .font(.title3.weight(.bold))
                    .foregroundColor(Theme.textPrimary)
                Text("Cole os HTMLs das páginas e toque em Analisar. A rule sai na aba JSON.")
                    .font(.callout)
                    .foregroundColor(Theme.textDim)
            }

            SectionTitle(title: "A rule")
            VStack(spacing: 10) {
                fieldRow(label: "Nome da rule") {
                    TextField("Ex.: MeuSite v1", text: $store.inputs.ruleName)
                        .focused($focusedField, equals: .ruleName)
                }
                fieldRow(label: "URL da lista (pode colar a página 2 — ele normaliza)") {
                    TextField("https://site.com/list/page/2.html", text: $store.inputs.siteUrl)
                        .focused($focusedField, equals: .siteUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                fieldRow(label: "URL inicial (reserva)") {
                    TextField("https://site.com/", text: $store.inputs.indexUrl)
                        .focused($focusedField, equals: .indexUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                fieldRow(label: "URL de busca (com {keyword})") {
                    TextField("https://site.com/?s={keyword}", text: $store.inputs.searchUrl)
                        .focused($focusedField, equals: .searchUrl)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .panelCard()

            SectionTitle(title: "Código-fonte (HTML)")
            htmlEditor(label: "HTML da LISTA — obrigatório", focus: .listHTML,
                       text: $store.inputs.listHTML)
            htmlEditor(label: "HTML do DETALHE — obrigatório", focus: .detailHTML,
                       text: $store.inputs.detailHTML)
            htmlEditor(label: "HTML da PÁGINA DE VÍDEO — opcional (vídeo em página separada)",
                       focus: .videoHTML, text: $store.inputs.videoHTML)

            Button {
                store.analyzeAll()
            } label: {
                HStack(spacing: 8) {
                    if store.isBusy {
                        ProgressView()
                            .tint(.black)
                    }
                    Text(store.isBusy ? "Analisando…" : "Analisar tudo")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Theme.gold)
                .foregroundColor(.black)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .disabled(store.isBusy)

            Button {
                saveName = store.inputs.ruleName
                showSaveAlert = true
            } label: {
                Text("Salvar teste")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(Theme.gold, lineWidth: 1))
                    .foregroundColor(Theme.gold)
            }

            if !store.statusMessage.isEmpty {
                Text(store.statusMessage)
                    .font(.footnote)
                    .foregroundColor(Theme.ok)
            }
        }
        .alert("Salvar teste", isPresented: $showSaveAlert) {
            TextField("Nome do teste", text: $saveName)
            Button("Salvar") { store.saveCurrent(name: saveName) }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Guarda as entradas atuais pra reabrir depois na aba Salvos.")
        }
    }

    private func fieldRow<Content: View>(label: String, @ViewBuilder field: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.textDim)
            field()
                .font(.system(.callout, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .padding(9)
                .background(Color(white: 0.12))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func htmlEditor(label: String, focus: FocusField, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.textDim)
                Spacer()
                Text("\(text.wrappedValue.count) caracteres")
                    .font(.caption2)
                    .foregroundColor(Theme.textDim)
            }
            TextEditor(text: text)
                .focused($focusedField, equals: focus)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color(white: 0.10))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                // Altura fixa: sem teto, o TextEditor dentro do ScrollView da
                // aba expande até a altura de todo o HTML colado. Com 200pt
                // ele rola internamente e mostra um trecho útil do código
                // (fonte caption2 mono, ~25 linhas) sem dominar a tela.
                .frame(height: 200)
            HStack(spacing: 10) {
                Button("Colar") {
                    if let s = UIPasteboard.general.string { text.wrappedValue = s }
                }
                .font(.caption.weight(.semibold))
                .foregroundColor(Theme.gold)
                Button("Limpar") { text.wrappedValue = "" }
                    .font(.caption.weight(.semibold))
                    .foregroundColor(Theme.danger)
                Spacer()
                if !text.wrappedValue.isEmpty {
                    Button("Copiar") { UIPasteboard.general.string = text.wrappedValue }
                        .font(.caption.weight(.semibold))
                        .foregroundColor(Theme.gold)
                }
            }
        }
        .panelCard()
    }
}
