import SwiftUI
import UIKit

/// Aba JSON: a rule gerada (fonte única é o estado) + o relatório Debug.
struct JSONTabView: View {
    @EnvironmentObject var store: YegenStore
    @State private var copiedLabel = ""

    var body: some View {
        TabScroll(title: "JSON") {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: "Checagem rápida")
                DataRow(label: "Domain", value: Engine.siteOrigin(store.inputs))
                DataRow(label: "indexUrl final", value: store.pagination.indexUrl)
                DataRow(label: "Vídeo escolhido", value: store.chosenVideo.map { "[\($0.family)] \($0.finalURL)" } ?? "(nenhum)")
            }
            .panelCard()

            if store.ruleReady {
                HStack {
                    SectionTitle(title: "Rule (JSON)")
                    Spacer()
                    Button("Copiar JSON") {
                        UIPasteboard.general.string = store.ruleJSON()
                        copiedLabel = "JSON copiado ✔"
                    }
                    .font(.caption.weight(.bold))
                    .foregroundColor(Theme.gold)
                }
                Text(store.ruleJSON())
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Theme.inset)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("O JSON aparece aqui depois de analisar a lista e o detalhe.")
                    .font(.callout)
                    .foregroundColor(Theme.textDim)
                    .panelCard()
            }

            HStack {
                SectionTitle(title: "Debug 🐞")
                Spacer()
                Button("Copiar Debug") {
                    UIPasteboard.general.string = store.debugReport()
                    copiedLabel = "Debug copiado ✔"
                }
                .font(.caption.weight(.bold))
                .foregroundColor(Theme.gold)
            }
            Text(store.debugReport())
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(Theme.textDim)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.inset)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            if !copiedLabel.isEmpty {
                Text(copiedLabel)
                    .font(.footnote)
                    .foregroundColor(Theme.ok)
            }
        }
        .onAppear { store.ensureAnalyzed() }
    }
}
