import Foundation

// MARK: - Campo da rule (tupla do Yealico)

/// Um campo de rule no formato do Yealico: selector + function + param +
/// regex + replacement. Chave ausente = nil (o JSON omite, como na web).
struct FieldRule: Equatable {
    var selector: String
    var function: String? = nil
    var param: String? = nil
    var regex: String? = nil
    var replacement: String? = nil

    var jval: JVal {
        var pairs: [(String, JVal)] = [("selector", .str(selector))]
        if let function { pairs.append(("function", .str(function))) }
        if let param { pairs.append(("param", .str(param))) }
        if let regex { pairs.append(("regex", .str(regex))) }
        if let replacement { pairs.append(("replacement", .str(replacement))) }
        return .obj(pairs)
    }

    /// Resumo de uma linha pro Debug e pras telas.
    var summary: String {
        var parts = ["selector: \(selector)"]
        if let function { parts.append("function: \(function)") }
        if let param { parts.append("param: \(param)") }
        if let regex { parts.append("regex: \(regex)") }
        if let replacement { parts.append("replacement: \(replacement)") }
        return parts.joined(separator: " | ")
    }
}

// MARK: - Entradas

struct YegenInputs: Codable, Equatable {
    var ruleName: String = ""
    var siteUrl: String = ""     // URL da página de lista (ele cola a pág. 2 — o motor normaliza)
    var indexUrl: String = ""    // URL inicial digitada (reserva)
    var searchUrl: String = ""   // URL de busca digitada
    var listHTML: String = ""
    var detailHTML: String = ""
    var videoHTML: String = ""   // página de vídeo separada (opcional)
}

// MARK: - Resultado da análise da lista

struct ListAnalysis {
    var itemSelector: String = ""
    var itemSignature: String = ""   // tag+classes do bloco (exclui a capa do detalhe)
    var itemCount: Int = 0
    var titleField: FieldRule? = nil
    var coverField: FieldRule? = nil
    var idCodeField: FieldRule? = nil
    var titleSample: String = ""
    var coverSample: String = ""
    var idCodeSample: String = ""    // URL absoluta do detalhe do item 1
    var detailSamples: [String] = [] // URLs absolutas amostradas (exclusão nas categorias)
    var strictTitle: String = ""     // "7/8"
    var strictCover: String = ""
    var strictIdCode: String = ""
    var notes: [String] = []
}

// MARK: - Candidato de vídeo

struct VideoCandidate: Identifiable {
    let id = UUID()
    var family: String        // "MacCMS (player_aaaa)", "og:video", …
    var field: FieldRule      // a tupla que entra no videoRule.url
    var finalURL: String      // URL extraída no modo estrito
    var score: Int
    var source: String        // "detalhe" ou "página de vídeo"
    var note: String = ""
}

// MARK: - Resultado da análise do detalhe

struct DetailAnalysis {
    var titleField: FieldRule? = nil
    var titleSample: String = ""
    /// Candidato de capa detectado (a emissão troca o selector pra "this").
    var coverCandidate: FieldRule? = nil
    var coverSample: String = ""
    var coverSource: String = ""     // "og:image" ou "fallback (imagem de conteúdo)"
    var ogDescription: String? = nil
    var videos: [VideoCandidate] = []
    var tagItemSelector: String? = nil
    var tagField: FieldRule? = nil   // url das tags (name é sempre this/text)
    var tagCount: Int = 0
    var tagSample: String = ""
    var notes: [String] = []
}

// MARK: - Categorias

struct CategoryLink: Identifiable, Equatable {
    var id: String { url }
    var name: String
    var url: String        // URL absoluta da página 1
    var selected: Bool = true
}

// MARK: - Paginação

struct PaginationInfo {
    enum Kind { case none, pageFormat, queryDirect }
    var kind: Kind = .none
    var label: String = "sem paginação detectada"
    var indexUrl: String = ""    // URL emitida no JSON (com o template)
    var page1Url: String = ""    // página 1 canônica
    var core: String = ""        // ex.: "/page/{page:}" (pageFormat)
    var paramName: String = ""   // ex.: "page" (queryDirect)

    /// Aplica o padrão de paginação do site a uma URL de categoria/tag.
    func paginate(_ url: String) -> String {
        switch kind {
        case .none:
            return url
        case .pageFormat:
            let template = "{pageFormat:\(core)}"
            if url.hasSuffix(".html") {
                return String(url.dropLast(5)) + template + ".html"
            }
            return url + template
        case .queryDirect:
            let sep = url.contains("?") ? "&" : "?"
            return url + sep + "\(paramName)={page:}"
        }
    }
}

// MARK: - Teste salvo

struct SavedTest: Codable, Identifiable {
    var id: String = UUID().uuidString
    var name: String
    var savedAt: Date
    var inputs: YegenInputs
    var selectedVideoFamily: String? = nil
    var deselectedCategories: [String] = []

    var dateLabel: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "pt_BR")
        f.dateFormat = "dd/MM/yyyy HH:mm"
        return f.string(from: savedAt)
    }
}
