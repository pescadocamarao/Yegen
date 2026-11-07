import SwiftUI

/// v1.3.1 — Raiz da casca: SÓ a WKWebView em tela cheia com o Yegen web
/// embarcado. A barrinha nativa flutuante (Backup iCloud / Restaurar no
/// canto superior) foi REMOVIDA a pedido do usuário — ela cobria as
/// abas da página e atrapalhava a navegação. As ações da casca agora
/// moram na barra inferior da própria página (web v3.29), só com
/// símbolos: ⬆ 💾 📂 e, na casca, ☁️⬆ Backup / ☁️⬇ Restaurar, que
/// chegam aqui pelo message handler `yegenShell`. O único resíduo
/// nativo visível é o aviso transitório de status (some sozinho, em
/// cima da barra da página) e os diálogos/folhas do sistema.
struct ContentView: View {
    @StateObject private var shell = ShellController()

    var body: some View {
        ZStack(alignment: .bottom) {
            WebShellView(controller: shell)
                .ignoresSafeArea()

            if let status = shell.status {
                Text(status)
                    .font(.caption2.weight(.medium))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.72), in: Capsule())
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    // Acima da barra inferior fixa da página.
                    .padding(.bottom, 76)
            }
        }
        .background(Color.black)
        .confirmationDialog(
            "Restaurar o backup?",
            isPresented: $shell.confirmRestore,
            titleVisibility: .visible
        ) {
            Button("Restaurar backup") { shell.requestRestore() }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("Os testes do backup entram no armazenamento da página (os de mesmo id são atualizados) e a página recarrega.")
        }
        .sheet(item: $shell.shareItem) { item in
            ShareSheet(url: item.url)
        }
    }
}
