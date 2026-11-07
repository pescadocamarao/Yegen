import SwiftUI

/// Visual do app: escuro e compacto, tipografia técnica (monoespaçada nos
/// dados) e dourado APENAS em ações e destaques — mesma família visual do
/// BaixaVídeos, com o dourado da lupa do Yegen no lugar do verde-lima.
/// (v1.2, bisseção 6: tokens estáticos da paleta Meia-Noite; os nomes novos
/// — inset/panel2/accentInk/accentSoft/textFaint — ficam pra as views.)
enum Theme {
    static let background = Color(red: 0.05, green: 0.07, blue: 0.09)   // #0d1117
    static let panel = Color(red: 0.09, green: 0.11, blue: 0.15)        // #161c26
    static let panel2 = Color(red: 0.11, green: 0.15, blue: 0.20)       // #1d2532
    static let inset = Color(red: 0.04, green: 0.05, blue: 0.08)        // #0a0e14
    static let panelBorder = Color(red: 0.17, green: 0.21, blue: 0.28)  // #2b3547
    static let textPrimary = Color(red: 0.91, green: 0.94, blue: 0.96)  // #e9eef6
    static let textDim = Color(red: 0.60, green: 0.65, blue: 0.73)      // #98a6bb
    static let textFaint = Color(red: 0.43, green: 0.49, blue: 0.58)    // #6d7c93
    static let gold = Color(red: 0.95, green: 0.66, blue: 0.23)         // #f2a93b
    static let accentInk = Color(red: 0.13, green: 0.08, blue: 0.01)    // #201503
    static let accentSoft = Color(red: 1.00, green: 0.85, blue: 0.54)   // #ffd98a
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
