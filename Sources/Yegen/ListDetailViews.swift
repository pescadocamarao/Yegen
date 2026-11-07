import SwiftUI
import UIKit

// MARK: - Aba Lista

struct ListTabView: View {
    @EnvironmentObject var store: YegenStore

    var body: some View {
        TabScroll(title: "Lista") {
            if let list = store.listAnalysis {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Bloco de itens")
                    DataRow(label: "Seletor do item", value: list.itemSelector)
                    DataRow(label: "Assinatura (tag+classes)", value: list.itemSignature)
                    DataRow(label: "Itens encontrados", value: "\(list.itemCount)")
                }
                .panelCard()

                fieldPanel(title: "Título", field: list.titleField,
                           sample: list.titleSample, strict: list.strictTitle)
                fieldPanel(title: "Capa", field: list.coverField,
                           sample: list.coverSample, strict: list.strictCover)
                fieldPanel(title: "idCode (link do detalhe)", field: list.idCodeField,
                           sample: list.idCodeSample, strict: list.strictIdCode)

                if !list.notes.isEmpty {
                    notesPanel(list.notes)
                }
            } else {
                EmptyAnalysisView(text: "Nenhuma análise ainda.\nCole o HTML da lista na aba Entradas e toque em Analisar tudo.")
            }
        }
        .onAppear { store.ensureAnalyzed() }
    }

    private func fieldPanel(title: String, field: FieldRule?, sample: String, strict: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: title)
            if let field {
                DataRow(label: "Campo (como vai no JSON)", value: field.summary)
                if !strict.isEmpty { DataRow(label: "Teste estrito", value: strict + " itens") }
                if !sample.isEmpty { DataRow(label: "Exemplo (item 1)", value: sample) }
            } else {
                Text("Não detectado no teste estrito.")
                    .font(.callout)
                    .foregroundColor(Theme.danger)
            }
        }
        .panelCard()
    }

    private func notesPanel(_ notes: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(title: "Notas")
            ForEach(notes, id: \.self) { note in
                Text("• " + note)
                    .font(.footnote)
                    .foregroundColor(Theme.textDim)
            }
        }
        .panelCard()
    }
}

// MARK: - Aba Detalhe

struct DetailTabView: View {
    @EnvironmentObject var store: YegenStore

    var body: some View {
        TabScroll(title: "Detalhe") {
            if let detail = store.detailAnalysis {
                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Título do detalhe")
                    if let f = detail.titleField {
                        DataRow(label: "Campo", value: f.summary)
                        DataRow(label: "Valor", value: detail.titleSample)
                    } else {
                        Text("Não detectado.").font(.callout).foregroundColor(Theme.danger)
                    }
                }
                .panelCard()

                VStack(alignment: .leading, spacing: 8) {
                    SectionTitle(title: "Capa do detalhe")
                    if let candidate = detail.coverCandidate {
                        DataRow(label: "Candidato detectado (\(detail.coverSource))", value: candidate.summary)
                        DataRow(label: "Emissão no JSON", value: "selector: this — lei da capa do detalhe (só o seletor troca)")
                        DataRow(label: "Valor", value: detail.coverSample)
                    } else {
                        Text("Sem capa — o detalhe sai sem cover.")
                            .font(.callout).foregroundColor(Theme.textDim)
                    }
                }
                .panelCard()

                videoPanel(detail)

                if let itemSel = detail.tagItemSelector, let urlField = detail.tagField {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionTitle(title: "Tags")
                        DataRow(label: "Item", value: itemSel)
                        DataRow(label: "URL das tags", value: urlField.summary)
                        DataRow(label: "Detectadas", value: "\(detail.tagCount) — ex.: \(detail.tagSample)")
                    }
                    .panelCard()
                }

                if !detail.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionTitle(title: "Notas")
                        ForEach(detail.notes, id: \.self) { note in
                            Text("• " + note)
                                .font(.footnote)
                                .foregroundColor(Theme.textDim)
                        }
                    }
                    .panelCard()
                }
            } else {
                EmptyAnalysisView(text: "Nenhuma análise ainda.\nCole o HTML do detalhe na aba Entradas e toque em Analisar tudo.")
            }
        }
        .onAppear { store.ensureAnalyzed() }
    }

    private func videoPanel(_ detail: DetailAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle(title: "Vídeo — candidatos")
            if detail.videos.isEmpty {
                Text("Nenhum candidato confirmado no HTML cru.")
                    .font(.callout)
                    .foregroundColor(Theme.textDim)
            } else {
                if let chosen = store.chosenVideo {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.isManualSelection ? "SELECIONADO POR VOCÊ" : "PRÉ-SELECIONADO (ranking)")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Theme.gold)
                        DataRow(label: "Família", value: chosen.family)
                        DataRow(label: "URL final", value: chosen.finalURL)
                        Text("A desc do detalhe espelha esta URL no app (conferência).")
                            .font(.caption2)
                            .foregroundColor(Theme.textDim)
                    }
                    .padding(10)
                    .background(Theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if store.isManualSelection {
                        Button("Voltar ao automático") { store.clearVideoSelection() }
                            .font(.caption.weight(.semibold))
                            .foregroundColor(Theme.gold)
                    }
                }
                Text("Toque num candidato pra trocar — a sua escolha é soberana e nunca é sobrescrita.")
                    .font(.caption2)
                    .foregroundColor(Theme.textDim)
                ForEach(detail.videos) { cand in
                    candidateRow(cand, isChosen: store.chosenVideo?.finalURL == cand.finalURL
                                 && store.chosenVideo?.family == cand.family)
                }
            }
        }
        .panelCard()
    }

    private func candidateRow(_ cand: VideoCandidate, isChosen: Bool) -> some View {
        Button {
            store.selectVideo(cand)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(cand.family)
                        .font(.footnote.weight(.bold))
                        .foregroundColor(isChosen ? Theme.gold : Theme.textPrimary)
                    Spacer()
                    Text("\(cand.score) pts")
                        .font(.caption2)
                        .foregroundColor(Theme.textDim)
                }
                Text(cand.finalURL)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Theme.textDim)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    Text(cand.source)
                        .font(.caption2)
                        .foregroundColor(Theme.textDim)
                    if isChosen {
                        Text("✔ ESCOLHIDO")
                            .font(.caption2.weight(.bold))
                            .foregroundColor(Theme.ok)
                    }
                }
                if !cand.note.isEmpty {
                    Text(cand.note)
                        .font(.caption2)
                        .foregroundColor(Theme.danger)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(isChosen ? Theme.gold : Theme.panelBorder, lineWidth: isChosen ? 2 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
