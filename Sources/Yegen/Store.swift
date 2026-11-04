import Foundation
import SwiftUI

/// Estado central do app: entradas, análises, seleção soberana de vídeo,
/// categorias e os testes salvos (Documents/yegen-salvos.json).
final class YegenStore: ObservableObject {
    @Published var inputs = YegenInputs()
    @Published var listAnalysis: ListAnalysis?
    @Published var detailAnalysis: DetailAnalysis?
    @Published var categories: [CategoryLink] = []
    @Published var pagination = PaginationInfo()
    @Published var savedTests: [SavedTest] = []
    @Published var statusMessage: String = ""

    /// Chave da seleção manual de vídeo (família|URL) — sobrevive à reanálise.
    @Published private(set) var selectedVideoKey: String?
    private var analyzedSnapshot: YegenInputs?

    init() { loadSavedTests() }

    var isStale: Bool { analyzedSnapshot != inputs }
    var hasAnalysis: Bool { listAnalysis != nil || detailAnalysis != nil }

    // MARK: - Análise

    func ensureAnalyzed() {
        guard isStale else { return }
        if !inputs.listHTML.isEmpty || !inputs.detailHTML.isEmpty {
            analyzeAll()
        }
    }

    func analyzeAll() {
        let previousKey = selectedVideoKey
        listAnalysis = Engine.analyzeList(inputs: inputs)
        pagination = Engine.detectPagination(inputs: inputs)
        if let doc = Engine.parse(inputs.listHTML) {
            categories = Engine.detectCategories(doc: doc, list: listAnalysis,
                                                 origin: Engine.siteOrigin(inputs))
        } else {
            categories = []
        }
        detailAnalysis = Engine.analyzeDetail(inputs: inputs, list: listAnalysis)
        // A seleção manual é soberana: se o candidato ainda existe, ela fica.
        if let key = previousKey,
           !(detailAnalysis?.videos.contains { videoKey($0) == key } ?? false) {
            selectedVideoKey = nil
        }
        analyzedSnapshot = inputs
        let videoCount = detailAnalysis?.videos.count ?? 0
        statusMessage = "Análise pronta: \(listAnalysis?.itemCount ?? 0) itens, "
            + "\(categories.count) categorias, \(videoCount) candidatos de vídeo."
    }

    // MARK: - Vídeo (seleção manual soberana)

    static func videoKey(_ v: VideoCandidate) -> String { v.family + "|" + v.finalURL }
    private func videoKey(_ v: VideoCandidate) -> String { Self.videoKey(v) }

    var chosenVideo: VideoCandidate? {
        guard let videos = detailAnalysis?.videos, !videos.isEmpty else { return nil }
        if let key = selectedVideoKey,
           let manual = videos.first(where: { videoKey($0) == key }) {
            return manual
        }
        return videos.first   // ranking já vem ordenado por pontos
    }

    var isManualSelection: Bool {
        guard let key = selectedVideoKey, let chosen = chosenVideo else { return false }
        return videoKey(chosen) == key
    }

    func selectVideo(_ v: VideoCandidate) {
        selectedVideoKey = videoKey(v)
        statusMessage = "Vídeo selecionado por você: \(v.family)."
    }

    func clearVideoSelection() {
        selectedVideoKey = nil
    }

    // MARK: - Rule / Debug

    var ruleReady: Bool { listAnalysis != nil && detailAnalysis != nil }

    func ruleJSON() -> String {
        Engine.buildRule(inputs: inputs, list: listAnalysis, detail: detailAnalysis,
                         categories: categories, pagination: pagination,
                         chosenVideo: chosenVideo).serialized()
    }

    func debugReport() -> String {
        DebugReport.build(inputs: inputs, list: listAnalysis, detail: detailAnalysis,
                          categories: categories, pagination: pagination,
                          chosenVideo: chosenVideo, jsonReady: ruleReady)
    }

    // MARK: - Salvos (persistência local)

    private var savedFileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("yegen-salvos.json")
    }

    private func persistSavedTests() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(savedTests) {
            try? data.write(to: savedFileURL, options: .atomic)
        }
    }

    private func loadSavedTests() {
        guard let data = try? Data(contentsOf: savedFileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let tests = try? decoder.decode([SavedTest].self, from: data) {
            savedTests = tests
        }
    }

    func saveCurrent(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let test = SavedTest(
            name: trimmed.isEmpty ? (inputs.ruleName.isEmpty ? "Sem nome" : inputs.ruleName) : trimmed,
            savedAt: Date(),
            inputs: inputs,
            selectedVideoFamily: chosenVideo?.family,
            deselectedCategories: categories.filter { !$0.selected }.map { $0.url })
        savedTests.insert(test, at: 0)
        persistSavedTests()
        statusMessage = "Teste salvo: \(test.name)."
    }

    func load(_ test: SavedTest) {
        inputs = test.inputs
        selectedVideoKey = nil
        analyzeAll()
        // Restaura categorias desmarcadas e a família de vídeo escolhida.
        if !test.deselectedCategories.isEmpty {
            for i in categories.indices where test.deselectedCategories.contains(categories[i].url) {
                categories[i].selected = false
            }
        }
        if let family = test.selectedVideoFamily,
           let match = detailAnalysis?.videos.first(where: { $0.family == family }) {
            selectedVideoKey = videoKey(match)
        }
        statusMessage = "Teste carregado: \(test.name)."
    }

    func deleteTests(at offsets: IndexSet) {
        savedTests.remove(atOffsets: offsets)
        persistSavedTests()
    }
}
