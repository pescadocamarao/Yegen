import SwiftUI
import WebKit
import UIKit

// MARK: - Pontes injetadas (JS)
//
// A página embarcada é a v3.28 INTACTA — nenhuma lógica dela muda. As
// pontes são shims injetados pela casca nos pontos exatos em que a
// página usa APIs que a WKWebView restringe:
//
// 1) COLAR — `pasteIntoField()` (botões [data-paste]) chama
//    `navigator.clipboard.readText()`. O shim troca readText/writeText
//    por uma ida-e-volta ao UIPasteboard via message handler:
//    readText devolve uma Promise que a casca resolve chamando
//    `window.__yegenResolvePaste(id, texto)`. writeText grava direto
//    no UIPasteboard (é o que o `copyText()` da página espera).
// 2) DOWNLOADS — toda saída de arquivo da página passa por
//    `deliverFile()`: (a) Web Share com File, (b) painel interno de
//    copiar, (c) download clássico Blob + <a download>. O shim cobre
//    (a) e (c) sem tocar na lógica: define `navigator.share`/
//    `canShare` que leem o File e entregam {filename, text} à casca
//    (que grava e abre a folha de compartilhamento nativa — o passo
//    (a) da página passa a funcionar de verdade), e captura cliques
//    em <a download> de blob: na fase de captura, lê o Blob como
//    texto e entrega do mesmo jeito. Se o share nativo falhar, o
//    painel (b) da página continua como rede de segurança dela.
// 3) BACKUP/RESTAURO — as funções de exportar/importar da página vivem
//    num escopo fechado (não são globais), então a ponte fala direto
//    com o armazenamento dela: o IndexedDB `yegen-testes-salvos`,
//    store `tests` (o mesmo que `idbGetAll`/`idbPutMany` da página
//    usam). Backup = getAll → JSON no formato do Exportar da página
//    ({app:"Yegen", tests:[...]}). Restauro = put de cada teste
//    (preservando o `id`; sem id, gera um) e reload da página, que
//    relê o banco e renderiza — a semântica é a do banco, sem passar
//    pelo dedup nome|siteUrl do importar da página (declarado).

enum ShellScripts {
    static let bridge = """
    (function(){
      if (window.__yegenShellBridge) return;
      window.__yegenShellBridge = true;
      var seq = 0;
      var pasteResolvers = {};
      window.__yegenResolvePaste = function(id, text){
        var r = pasteResolvers[id];
        if (r) { delete pasteResolvers[id]; r(text == null ? "" : String(text)); }
      };
      function nativeReadText(){
        return new Promise(function(resolve){
          var id = ++seq;
          pasteResolvers[id] = resolve;
          try { window.webkit.messageHandlers.yegenPaste.postMessage({ id: id }); }
          catch(e){ delete pasteResolvers[id]; resolve(""); }
          setTimeout(function(){
            if (pasteResolvers[id]) { delete pasteResolvers[id]; resolve(""); }
          }, 15000);
        });
      }
      function nativeWriteText(t){
        try { window.webkit.messageHandlers.yegenCopy.postMessage({ text: t == null ? "" : String(t) }); }
        catch(e){}
        return Promise.resolve();
      }
      var shellClipboard = { readText: nativeReadText, writeText: nativeWriteText };
      function nativeShare(data){
        return new Promise(function(resolve){
          var files = data && data.files;
          if (files && files.length) {
            var f = files[0];
            f.text().then(function(text){
              try { window.webkit.messageHandlers.yegenDownload.postMessage({ filename: f.name || "yegen-download", text: text }); }
              catch(e){}
              resolve();
            }).catch(function(){ resolve(); });
          } else { resolve(); }
        });
      }
      function nativeCanShare(data){ return !!(data && data.files && data.files.length); }
      function installBridges(){
        try {
          Object.defineProperty(navigator, "clipboard", { value: shellClipboard, configurable: true });
        } catch(e){
          try {
            if (navigator.clipboard) {
              navigator.clipboard.readText = nativeReadText;
              navigator.clipboard.writeText = nativeWriteText;
            }
          } catch(e2){}
        }
        try { Object.defineProperty(navigator, "share", { value: nativeShare, configurable: true }); } catch(e){}
        try { Object.defineProperty(navigator, "canShare", { value: nativeCanShare, configurable: true }); } catch(e){}
      }
      installBridges();
      document.addEventListener("DOMContentLoaded", installBridges);
      document.addEventListener("click", function(e){
        var t = e.target;
        var a = t && t.closest ? t.closest("a[download]") : null;
        if (!a) return;
        var href = a.getAttribute("href") || "";
        if (href.indexOf("blob:") !== 0) return;
        e.preventDefault();
        e.stopPropagation();
        var name = a.getAttribute("download") || "yegen-download";
        fetch(href).then(function(r){ return r.text(); }).then(function(text){
          window.webkit.messageHandlers.yegenDownload.postMessage({ filename: name, text: text });
        }).catch(function(){});
      }, true);
      function openSavedDb(){
        return new Promise(function(res, rej){
          var rq = indexedDB.open("yegen-testes-salvos", 1);
          rq.onsuccess = function(){ res(rq.result); };
          rq.onerror = function(){ rej(rq.error || new Error("indexedDB")); };
          rq.onblocked = function(){ rej(new Error("indexedDB blocked")); };
        });
      }
      window.__yegenNativeBackup = function(){
        openSavedDb().then(function(db){
          var rq = db.transaction("tests", "readonly").objectStore("tests").getAll();
          rq.onsuccess = function(){
            var arr = Array.isArray(rq.result) ? rq.result : [];
            window.webkit.messageHandlers.yegenBackupData.postMessage({
              json: JSON.stringify({ app: "Yegen", tests: arr })
            });
          };
          rq.onerror = function(){
            window.webkit.messageHandlers.yegenBackupData.postMessage({ error: "leitura do IndexedDB falhou" });
          };
        }).catch(function(e){
          window.webkit.messageHandlers.yegenBackupData.postMessage({ error: String(e && e.message || e) });
        });
      };
      window.__yegenNativeRestore = function(json){
        var list = null;
        try {
          var data = JSON.parse(json);
          list = Array.isArray(data) ? data : (data && Array.isArray(data.tests) ? data.tests : null);
        } catch(e){}
        if (!list) {
          window.webkit.messageHandlers.yegenRestoreResult.postMessage({ ok: false, error: "backup inválido" });
          return;
        }
        openSavedDb().then(function(db){
          var tx = db.transaction("tests", "readwrite");
          var st = tx.objectStore("tests");
          var n = 0;
          list.forEach(function(t){
            if (t && typeof t === "object") {
              if (!t.id) t.id = "t" + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
              st.put(t); n++;
            }
          });
          tx.oncomplete = function(){
            window.webkit.messageHandlers.yegenRestoreResult.postMessage({ ok: true, count: n });
            setTimeout(function(){ location.reload(); }, 700);
          };
          tx.onerror = function(){
            window.webkit.messageHandlers.yegenRestoreResult.postMessage({ ok: false, error: "gravação no IndexedDB falhou" });
          };
        }).catch(function(e){
          window.webkit.messageHandlers.yegenRestoreResult.postMessage({ ok: false, error: String(e && e.message || e) });
        });
      };
    })();
    """
}

// MARK: - Backup iCloud da casca
//
// O JSON do backup (formato do Exportar da página web) mora no MESMO
// contêiner iCloud da v1.2 (iCloud.com.seidao.yegen), em arquivo
// próprio — o YegenDataStore da v1.2 modelava o formato nativo antigo
// (envelope de SavedTest), incompatível com o payload do web, por isso
// a casca tem esta store dedicada. Espelho local em Documents pro caso
// de o iCloud estar indisponível nesta instalação.

final class WebBackupStore {
    static let containerID = "iCloud.com.seidao.yegen"
    static let fileName = "yegen-web-backup.json"

    private var iCloudFileURL: URL? {
        FileManager.default.url(forUbiquityContainerIdentifier: Self.containerID)?
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    private var localFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.fileName)
    }

    private func coordinatedWrite(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing],
                                       error: &coordError) { actual in
            try? data.write(to: actual, options: .atomic)
        }
    }

    private func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordError) { actual in
            result = try? Data(contentsOf: actual)
        }
        return result
    }

    /// Grava o backup nos dois destinos possíveis. Retorna onde gravou.
    func save(_ data: Data) -> String {
        coordinatedWrite(data, to: localFileURL)
        if let iCloud = iCloudFileURL {
            coordinatedWrite(data, to: iCloud)
            return "iCloud"
        }
        return "aparelho"
    }

    enum LoadResult {
        case ok(Data, String)
        case downloading
        case missing
    }

    func load() -> LoadResult {
        if let iCloud = iCloudFileURL,
           FileManager.default.fileExists(atPath: iCloud.path) {
            let status = (try? iCloud.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus
            if status != nil && status != .current {
                try? FileManager.default.startDownloadingUbiquitousItem(at: iCloud)
                return .downloading
            }
            if let data = coordinatedRead(iCloud) { return .ok(data, "iCloud") }
        }
        if let data = coordinatedRead(localFileURL) { return .ok(data, "aparelho") }
        return .missing
    }
}

// MARK: - Controlador da casca

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

final class ShellController: NSObject, ObservableObject {
    @Published var status: String?
    @Published var shareItem: ShareItem?
    @Published var confirmRestore = false

    private(set) var webView: WKWebView?
    private let backupStore = WebBackupStore()
    private var statusGeneration = 0

    func attach(_ webView: WKWebView) { self.webView = webView }

    func showStatus(_ message: String) {
        statusGeneration += 1
        let gen = statusGeneration
        status = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            if self?.statusGeneration == gen { self?.status = nil }
        }
    }

    // MARK: Ações da barra nativa

    func requestBackup() {
        webView?.evaluateJavaScript(
            "window.__yegenNativeBackup && window.__yegenNativeBackup();")
    }

    func requestRestore() {
        switch backupStore.load() {
        case .downloading:
            showStatus("Backup do iCloud ainda baixando — tente de novo em instantes.")
        case .missing:
            showStatus("Nenhum backup encontrado (nem no iCloud, nem no aparelho).")
        case .ok(let data, _):
            guard let json = String(data: data, encoding: .utf8) else {
                showStatus("Backup ilegível.")
                return
            }
            let literal = Self.jsStringLiteral(json)
            webView?.evaluateJavaScript(
                "window.__yegenNativeRestore && window.__yegenNativeRestore(\(literal));")
        }
    }

    private static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        // text = ["..."] — devolve só o literal da string.
        return String(text.dropFirst().dropLast())
    }

    // MARK: Respostas às pontes

    fileprivate func handlePasteRequest(id: Int) {
        let text = UIPasteboard.general.string ?? ""
        let literal = Self.jsStringLiteral(text)
        webView?.evaluateJavaScript("window.__yegenResolvePaste && window.__yegenResolvePaste(\(id), \(literal));")
    }

    fileprivate func handleCopy(text: String) {
        UIPasteboard.general.string = text
    }

    fileprivate func handleDownload(filename: String, text: String) {
        let safeName = filename.isEmpty ? "yegen-download.txt" : filename
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(safeName)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareItem = ShareItem(url: url)
        } catch {
            showStatus("Não consegui gravar o arquivo do download.")
        }
    }

    fileprivate func handleBackupData(json: String?, error: String?) {
        if let error {
            showStatus("Backup falhou: \(error)")
            return
        }
        guard let json, let data = json.data(using: .utf8) else {
            showStatus("Backup falhou: resposta vazia da página.")
            return
        }
        let dest = backupStore.save(data)
        showStatus(dest == "iCloud"
            ? "Backup gravado no iCloud ☁️"
            : "Backup gravado neste aparelho (iCloud indisponível).")
    }

    fileprivate func handleRestoreResult(ok: Bool, count: Int, error: String?) {
        if ok {
            showStatus("Backup restaurado: \(count) teste(s). A página vai recarregar.")
        } else {
            showStatus("Restauro falhou: \(error ?? "erro desconhecido")")
        }
    }
}

// MARK: - WKWebView (UIViewRepresentable)

struct WebShellView: UIViewRepresentable {
    @ObservedObject var controller: ShellController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Persistência das "portas" do web (localStorage + IndexedDB):
        // data store padrão (persistente, no contêiner do app) — NUNCA o
        // .nonPersistent(). A página é copiada pra Application Support e
        // carregada via loadFileURL sempre do MESMO caminho, pra origem
        // file:// ser estável entre aberturas.
        config.websiteDataStore = .default()
        config.userContentController.add(
            WKUserScript(source: ShellScripts.bridge,
                         injectionTime: .atDocumentStart,
                         forMainFrameOnly: false))
        let coord = context.coordinator
        for name in ["yegenPaste", "yegenCopy", "yegenDownload",
                     "yegenBackupData", "yegenRestoreResult"] {
            config.userContentController.add(coord, name: name)
        }

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coord
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.backgroundColor = .black
        webView.isOpaque = false
        controller.attach(webView)

        if let fileURL = Self.preparePageFile() {
            webView.loadFileURL(fileURL,
                                allowingReadAccessTo: fileURL.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    /// Copia a página embarcada pra Application Support/YegenWeb/ na
    /// primeira abertura (e de novo quando o bundle traz página de
    /// tamanho diferente — ou seja, versão nova do web). Os dados da
    /// página (IndexedDB/localStorage) NÃO moram nesse arquivo: vivem
    /// no website data store, então trocar o HTML não apaga os salvos.
    private static func preparePageFile() -> URL? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("YegenWeb", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("yegen-web.html")

        var bundleURL = Bundle.main.url(forResource: "yegen-web", withExtension: "html")
        if bundleURL == nil {
            // Procura tolerante: qualquer .html na raiz do bundle.
            if let resourcePath = Bundle.main.resourcePath,
               let names = try? fm.contentsOfDirectory(atPath: resourcePath) {
                if let name = names.first(where: { $0.hasSuffix(".html") }) {
                    bundleURL = Bundle.main.bundleURL.appendingPathComponent(name)
                }
            }
        }
        guard let src = bundleURL else { return fm.fileExists(atPath: dest.path) ? dest : nil }

        let srcSize = (try? fm.attributesOfItem(atPath: src.path))?[.size] as? NSNumber
        let dstSize = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? NSNumber
        if srcSize != dstSize {
            try? fm.removeItem(at: dest)
            try? fm.copyItem(at: src, to: dest)
        }
        return dest
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let controller: ShellController
        init(controller: ShellController) { self.controller = controller }

        func userContentController(_ ucc: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            let body = message.body as? [String: Any] ?? [:]
            switch message.name {
            case "yegenPaste":
                controller.handlePasteRequest(id: body["id"] as? Int ?? 0)
            case "yegenCopy":
                controller.handleCopy(text: body["text"] as? String ?? "")
            case "yegenDownload":
                controller.handleDownload(filename: body["filename"] as? String ?? "",
                                          text: body["text"] as? String ?? "")
            case "yegenBackupData":
                controller.handleBackupData(json: body["json"] as? String,
                                            error: body["error"] as? String)
            case "yegenRestoreResult":
                controller.handleRestoreResult(ok: body["ok"] as? Bool ?? false,
                                               count: body["count"] as? Int ?? 0,
                                               error: body["error"] as? String)
            default:
                break
            }
        }

        // Links externos (Guia etc.) abrem no Safari; a página em si e
        // os recursos dela (subframes do Navegar, imagens) seguem na
        // WebView.
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url,
                  let scheme = url.scheme?.lowercased() else {
                decisionHandler(.allow); return
            }
            if (scheme == "http" || scheme == "https"),
               navigationAction.navigationType == .linkActivated,
               navigationAction.targetFrame?.isMainFrame == true {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

// MARK: - Folha de compartilhamento

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
