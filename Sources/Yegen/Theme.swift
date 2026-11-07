import Foundation
import SwiftUI

// MARK: - Paleta (espelho das variáveis CSS do Yegen web v3.28)

struct YegenPalette {
    let background: Color
    let panel: Color
    let panel2: Color
    let inset: Color
    let border: Color
    let text: Color
    let muted: Color
    let faint: Color
    let accent: Color
    let accentInk: Color
    let accentSoft: Color

    init(bg: String, panel: String, panel2: String, inset: String, border: String,
         text: String, muted: String, faint: String, accent: String,
         accentInk: String, accentSoft: String) {
        background = Color(hex: bg)
        self.panel = Color(hex: panel)
        self.panel2 = Color(hex: panel2)
        self.inset = Color(hex: inset)
        self.border = Color(hex: border)
        self.text = Color(hex: text)
        self.muted = Color(hex: muted)
        self.faint = Color(hex: faint)
        self.accent = Color(hex: accent)
        accentInk = Color(hex: accentInk)
        accentSoft = Color(hex: accentSoft)
    }
}

extension Color {
    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

// MARK: - Temas (os 6 do web, mesmos nomes e cores)

enum AppTheme: String, CaseIterable, Identifiable {
    case meiaNoite = "meia-noite"
    case neon = "neon"
    case oceano = "oceano"
    case sol = "sol"
    case esmeralda = "esmeralda"
    case dia = "dia"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .meiaNoite: return "Meia-Noite"
        case .neon: return "Neon Tóquio"
        case .oceano: return "Oceano"
        case .sol: return "Pôr do Sol"
        case .esmeralda: return "Esmeralda"
        case .dia: return "Dia Claro"
        }
    }

    var isLight: Bool { self == .dia }

    var palette: YegenPalette {
        switch self {
        case .meiaNoite:
            return YegenPalette(bg: "#0d1117", panel: "#161c26", panel2: "#1d2532",
                                inset: "#0a0e14", border: "#2b3547", text: "#e9eef6",
                                muted: "#98a6bb", faint: "#6d7c93", accent: "#f2a93b",
                                accentInk: "#201503", accentSoft: "#ffd98a")
        case .neon:
            return YegenPalette(bg: "#05060f", panel: "#0e1024", panel2: "#151838",
                                inset: "#03040a", border: "#2c3168", text: "#f3f1ff",
                                muted: "#a6aad9", faint: "#7176ad", accent: "#ff2e88",
                                accentInk: "#ffffff", accentSoft: "#67e8f9")
        case .oceano:
            return YegenPalette(bg: "#03202c", panel: "#06303f", panel2: "#0a4155",
                                inset: "#02161e", border: "#166077", text: "#ecfeff",
                                muted: "#9fc9d4", faint: "#64909d", accent: "#2dd4bf",
                                accentInk: "#02202a", accentSoft: "#7dd3fc")
        case .sol:
            return YegenPalette(bg: "#2b1210", panel: "#3a1a14", panel2: "#4a241b",
                                inset: "#1c0b08", border: "#71402a", text: "#fff4ec",
                                muted: "#d9b49c", faint: "#a97e63", accent: "#ff7a45",
                                accentInk: "#2a0d02", accentSoft: "#ffc46b")
        case .esmeralda:
            return YegenPalette(bg: "#06180f", panel: "#0b281a", panel2: "#103626",
                                inset: "#03110a", border: "#1f5138", text: "#ecfdf3",
                                muted: "#9fc9ae", faint: "#66997a", accent: "#34d399",
                                accentInk: "#032117", accentSoft: "#a7f3d0")
        case .dia:
            return YegenPalette(bg: "#f3f0e9", panel: "#ffffff", panel2: "#f5f2ea",
                                inset: "#fbfaf6", border: "#d8d2c2", text: "#1c2430",
                                muted: "#55606e", faint: "#8a94a3", accent: "#2563eb",
                                accentInk: "#ffffff", accentSoft: "#1d4ed8")
        }
    }
}

// MARK: - Densidade (Confortável / Compacto, como no web)

enum AppDensity: String, CaseIterable, Identifiable {
    case confortavel = "confortavel"
    case compacto = "compacto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .confortavel: return "Confortável"
        case .compacto: return "Compacto"
        }
    }

    /// Preenchimento dos cartões (web: 16px → 11px no compacto).
    var cardPadding: CGFloat { self == .compacto ? 9 : 12 }
    /// Espaçamento/padding das pilhas das abas.
    var stackSpacing: CGFloat { self == .compacto ? 10 : 14 }
    var dynamicTypeSize: DynamicTypeSize { self == .compacto ? .small : .medium }
}

// MARK: - Aparência (persistência local + iCloud KV)

/// Tema e densidade escolhidos, salvos no aparelho e sincronizados pelo
/// NSUbiquitousKeyValueStore (chegam aos outros aparelhos dele sozinhos).
final class AppearanceStore: ObservableObject {
    @Published var theme: AppTheme {
        didSet { Self.currentPalette = theme.palette; persist() }
    }
    @Published var density: AppDensity {
        didSet { Self.currentDensity = density; persist() }
    }

    /// Paleta vigente — lida pelos tokens estáticos de `Theme`.
    static var currentPalette: YegenPalette = AppTheme.meiaNoite.palette
    /// Densidade vigente — lida pelo `PanelCard` (sem @EnvironmentObject
    /// dentro de ViewModifier, que a toolchain do CI rejeitou na v1.2).
    static var currentDensity: AppDensity = .confortavel

    private static let themeKey = "yegen.appearance.theme"
    private static let densityKey = "yegen.appearance.density"
    private var kvObserver: NSObjectProtocol?

    init() {
        let kv = NSUbiquitousKeyValueStore.default
        kv.synchronize()
        let themeRaw = kv.string(forKey: Self.themeKey)
            ?? UserDefaults.standard.string(forKey: Self.themeKey)
            ?? AppTheme.meiaNoite.rawValue
        let densityRaw = kv.string(forKey: Self.densityKey)
            ?? UserDefaults.standard.string(forKey: Self.densityKey)
            ?? AppDensity.confortavel.rawValue
        theme = AppTheme(rawValue: themeRaw) ?? .meiaNoite
        density = AppDensity(rawValue: densityRaw) ?? .confortavel
        Self.currentPalette = theme.palette
        Self.currentDensity = density
        // Mudança vinda de outro aparelho (iCloud KV) aplica na hora.
        kvObserver = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main) { [weak self] _ in
                guard let self else { return }
                let kv = NSUbiquitousKeyValueStore.default
                if let raw = kv.string(forKey: Self.themeKey),
                   let t = AppTheme(rawValue: raw), t != self.theme {
                    self.theme = t
                }
                if let raw = kv.string(forKey: Self.densityKey),
                   let d = AppDensity(rawValue: raw), d != self.density {
                    self.density = d
                }
            }
    }

    private func persist() {
        UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey)
        UserDefaults.standard.set(density.rawValue, forKey: Self.densityKey)
        let kv = NSUbiquitousKeyValueStore.default
        kv.set(theme.rawValue, forKey: Self.themeKey)
        kv.set(density.rawValue, forKey: Self.densityKey)
        kv.synchronize()
    }
}

// MARK: - Tokens visuais (API estável: as abas leem da paleta vigente)

enum Theme {
    static var background: Color { AppearanceStore.currentPalette.background }
    static var panel: Color { AppearanceStore.currentPalette.panel }
    static var panel2: Color { AppearanceStore.currentPalette.panel2 }
    static var inset: Color { AppearanceStore.currentPalette.inset }
    static var panelBorder: Color { AppearanceStore.currentPalette.border }
    static var textPrimary: Color { AppearanceStore.currentPalette.text }
    static var textDim: Color { AppearanceStore.currentPalette.muted }
    static var textFaint: Color { AppearanceStore.currentPalette.faint }
    /// Nome histórico no código: é o `accent` do tema vigente.
    static var gold: Color { AppearanceStore.currentPalette.accent }
    static var accentInk: Color { AppearanceStore.currentPalette.accentInk }
    static var accentSoft: Color { AppearanceStore.currentPalette.accentSoft }
    static let danger = Color(red: 0.95, green: 0.35, blue: 0.30)
    static let ok = Color(red: 0.45, green: 0.85, blue: 0.45)
}

struct PanelCard: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(AppearanceStore.currentDensity.cardPadding)
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
