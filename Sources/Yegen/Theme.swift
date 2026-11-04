import SwiftUI

/// Visual do app: escuro e compacto, tipografia técnica (monoespaçada nos
/// dados) e dourado APENAS em ações e destaques — mesma família visual do
/// BaixaVídeos, com o dourado da lupa do Yegen no lugar do verde-lima.
enum Theme {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.04)
    static let panel = Color(red: 0.08, green: 0.10, blue: 0.08)
    static let panelBorder = Color(white: 0.16)
    static let textPrimary = Color(white: 0.92)
    static let textDim = Color(white: 0.55)
    static let gold = Color(red: 0.83, green: 0.69, blue: 0.22)
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.30)
    static let ok = Color(red: 0.45, green: 0.85, blue: 0.45)
}

struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .background(Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Theme.panelBorder, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

extension View {
    func panelCard() -> some View { modifier(PanelCard()) }
}

/// Cabeçalho de seção: "LISTA" em fonte técnica.
struct SectionTitle: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.footnote, design: .monospaced).weight(.bold))
            .foregroundColor(Theme.gold)
            .textCase(.uppercase)
    }
}

/// Linha "rótulo: valor" monoespaçada, com o valor selecionável.
struct DataRow: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(Theme.textDim)
            Text(value.isEmpty ? "—" : value)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(Theme.textPrimary)
                .textSelection(.enabled)
        }
    }
}
