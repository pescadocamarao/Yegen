import SwiftUI

/// v1.3 — A CASCA. Decisão do usuário: em vez de continuar portando o
/// Yegen web sistema por sistema pro Swift (a bancada da v1.2 mediu o
/// nativo em "<10% funcional"), o app vira uma casca fina em volta do
/// Yegen WEB de verdade (a página v3.28 embarcada, rodando numa
/// WKWebView em tela cheia) — idêntico por construção, porque é o mesmo
/// código. As abas SwiftUI antigas saíram da raiz e da compilação
/// (excluídas no project.yml; os arquivos continuam no repo como
/// histórico). A casca só acrescenta o que a WebView não faz sozinha:
/// pontes de clipboard e de downloads, e o backup iCloud dos dados.
@main
struct YegenApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
