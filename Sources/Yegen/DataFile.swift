import Foundation

/// Arquivo de dados dos Salvos (v1.2): um único JSON com todos os testes.
/// É o MESMO formato da exportação/importação — o que sai no "Exportar"
/// entra no "Importar" sem conversão.
struct YegenDataFile: Codable {
    var format: String = "yegen-dados"
    var version: Int = 1
    var exportedAt: Date? = nil
    var savedTests: [SavedTest] = []
}

/// Persistência durável dos Salvos.
///
/// Onde os dados moravam até a v1.1: `Documents/yegen-salvos.json` (array
/// solto de testes) — dentro do contêiner do app, some quando o app é
/// excluído ou quando a instalação muda de identidade/assinatura.
///
/// Desenho da v1.2:
/// - Formato novo (envelope `YegenDataFile`) em `yegen-dados.json`.
/// - Espelho no **contêiner iCloud Documents** (`iCloud.com.seidao.yegen`)
///   quando disponível: o arquivo sobrevive à exclusão do app e à troca
///   de aparelho/rota de instalação.
/// - Sem iCloud → o mesmo arquivo no Documents local (sobrevive a
///   atualizações do app).
/// - Migração automática na primeira abertura: lê o formato antigo
///   (arquivo legado no Documents e arrays soltos) sem perda e regrava
///   no desenho novo. Entre cópias candidatas vale a de modificação
///   mais recente.
/// - Leituras/escritas passam por NSFileCoordinator. Se a cópia do
///   iCloud ainda não baixou, o download é pedido e o iCloud NÃO é
///   sobrescrito nesta sessão (a cópia local manda até o download chegar).
final class YegenDataStore {
    static let containerID = "iCloud.com.seidao.yegen"
    static let fileName = "yegen-dados.json"
    static let legacyName = "yegen-salvos.json"

    /// URL do arquivo no contêiner iCloud (nil = iCloud indisponível).
    private(set) var iCloudFileURL: URL?
    /// A cópia do iCloud existe mas ainda está baixando: não escrever nela.
    private var iCloudDownloadPending = false

    init() {
        iCloudFileURL = Self.resolveICloudFileURL()
    }

    private static func resolveICloudFileURL() -> URL? {
        guard let container = FileManager.default.url(
            forUbiquityContainerIdentifier: containerID) else { return nil }
        return container
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private var localFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.fileName)
    }

    private var legacyFileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Self.legacyName)
    }

    var usesICloud: Bool { iCloudFileURL != nil && !iCloudDownloadPending }

    var locationDescription: String {
        if iCloudFileURL != nil {
            return iCloudDownloadPending
                ? "Salvos no aparelho — cópia do iCloud ainda baixando."
                : "Salvos sincronizados no iCloud (sobrevivem a apagar o app)."
        }
        return "Salvos neste aparelho (iCloud indisponível nesta instalação)."
    }

    // MARK: - Decodificação tolerante (envelope novo ou array legado)

    static func decodeTests(from data: Data) -> [SavedTest]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let envelope = try? decoder.decode(YegenDataFile.self, from: data) {
            return envelope.savedTests
        }
        if let bare = try? decoder.decode([SavedTest].self, from: data) {
            return bare
        }
        return nil
    }

    static func encodeData(tests: [SavedTest], exportedAt: Date? = nil) -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let envelope = YegenDataFile(exportedAt: exportedAt, savedTests: tests)
        return try? encoder.encode(envelope)
    }

    // MARK: - Leitura/escrita coordenadas

    private func coordinatedRead(_ url: URL) -> Data? {
        var result: Data?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [],
                                       error: &coordError) { actual in
            result = try? Data(contentsOf: actual)
        }
        return result
    }

    private func coordinatedWrite(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var coordError: NSError?
        NSFileCoordinator().coordinate(writingItemAt: url, options: [.forReplacing],
                                       error: &coordError) { actual in
            try? data.write(to: actual, options: .atomic)
        }
    }

    private func modificationDate(of url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate]
            as? Date ?? .distantPast
    }

    // MARK: - Carga (com migração) e gravação

    /// Carrega os testes da cópia válida mais recente e consolida o
    /// desenho novo (local + iCloud). Primeira abertura da v1.2 migra o
    /// `yegen-salvos.json` legado sem perda.
    func load() -> [SavedTest] {
        var candidates: [(date: Date, tests: [SavedTest])] = []

        if let iCloud = iCloudFileURL,
           FileManager.default.fileExists(atPath: iCloud.path) {
            let downloading = (try? iCloud.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                .ubiquitousItemDownloadingStatus != .current
            if downloading {
                iCloudDownloadPending = true
                try? FileManager.default.startDownloadingUbiquitousItem(at: iCloud)
            } else if let data = coordinatedRead(iCloud),
                      let tests = Self.decodeTests(from: data) {
                candidates.append((modificationDate(of: iCloud), tests))
            }
        }
        if let data = coordinatedRead(localFileURL),
           let tests = Self.decodeTests(from: data) {
            candidates.append((modificationDate(of: localFileURL), tests))
        }
        if let data = coordinatedRead(legacyFileURL),
           let tests = Self.decodeTests(from: data) {
            candidates.append((modificationDate(of: legacyFileURL), tests))
        }

        let winner = candidates.max(by: { $0.date < $1.date })?.tests ?? []
        // Consolida: regrava no formato novo nos dois destinos possíveis
        // (a escrita no iCloud é pulada enquanto o download está pendente).
        save(winner)
        return winner
    }

    func save(_ tests: [SavedTest]) {
        guard let data = Self.encodeData(tests: tests) else { return }
        coordinatedWrite(data, to: localFileURL)
        if let iCloud = iCloudFileURL, !iCloudDownloadPending {
            coordinatedWrite(data, to: iCloud)
        }
    }
}
