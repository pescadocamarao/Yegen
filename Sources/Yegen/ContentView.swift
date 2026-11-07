import SwiftUI

/// v1.3 — Raiz da casca: a WKWebView em tela cheia com o Yegen web
/// embarcado + uma barrinha nativa mínima e discreta (canto superior
/// direito, translúcida) com as duas ações que são da casca, não da
/// página: Backup iCloud e Restaurar. Todo o resto da experiência
/// (abas, temas, motor, Navegar) é a página web v3.28, intacta.
struct ContentView: View {
    @StateObject private var shell = ShellController()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebShellView(controller: shell)
                .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    Button {
                        shell.requestBackup()
                    } label: {
                        Label("Backup iCloud", systemImage: "icloud.and.arrow.up")
                            .font(.caption2.weight(.semibold))
                    }
                    Button {
                        shell.confirmRestore = true
                    } label: {
                        Label("Restaurar", systemImage: "icloud.and.arrow.down")
                            .font(.caption2.weight(.semibold))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(.white)
                .padding(6)
                .background(.black.opacity(0.45), in: Capsule())

                if let status = shell.status {
                    Text(status)
                        .font(.caption2.weight(.medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black.opacity(0.72), in: Capsule())
                        .multilineTextAlignment(.trailing)
                }
            }
            .padding(.top, 8)
            .padding(.trailing, 10)
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
