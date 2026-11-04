import Foundation

/// O relatório 🐞 Debug em texto puro, copiável — mesmo espírito da versão
/// web: entradas, lista, detalhe, categorias, paginação e o vídeo escolhido,
/// tudo declarado pra conferir a emissão.
enum DebugReport {

    static func build(inputs: YegenInputs, list: ListAnalysis?, detail: DetailAnalysis?,
                      categories: [CategoryLink], pagination: PaginationInfo,
                      chosenVideo: VideoCandidate?, jsonReady: Bool) -> String {
        var lines: [String] = []
        let df = DateFormatter()
        df.locale = Locale(identifier: "pt_BR")
        df.dateFormat = "dd/MM/yyyy HH:mm:ss"
        lines.append("DEBUG YEGEN NATIVO v1.0")
        lines.append("Data/hora: \(df.string(from: Date()))")
        lines.append("Nome da rule: \(inputs.ruleName.isEmpty ? "(sem nome)" : inputs.ruleName)")
        lines.append("Domain: \(Engine.siteOrigin(inputs))")
        lines.append("JSON pronto? \(jsonReady ? "SIM" : "NÃO — falta analisar lista/detalhe")")
        if let video = chosenVideo, !Engine.siteOrigin(inputs).isEmpty,
           !HTMLKit.host(of: video.finalURL).isEmpty,
           HTMLKit.host(of: video.finalURL) != HTMLKit.host(of: Engine.siteOrigin(inputs)) {
            lines.append("Headers da raiz: stream em outro host (\(HTMLKit.host(of: video.finalURL))) — Referer emitido")
        } else {
            lines.append("Headers da raiz: não emitidos (stream no mesmo host ou sem vídeo)")
        }
        lines.append("flags da raiz: (chave omitida — nenhuma flag ativa nesta versão)")
        lines.append("")

        lines.append("== ENTRADAS ==")
        lines.append("siteUrl digitada: \(inputs.siteUrl.isEmpty ? "(vazia)" : inputs.siteUrl)")
        lines.append("indexUrl digitada: \(inputs.indexUrl.isEmpty ? "(vazia)" : inputs.indexUrl)")
        lines.append("searchUrl digitada: \(inputs.searchUrl.isEmpty ? "(vazia)" : inputs.searchUrl)")
        lines.append("HTML da lista presente? \(inputs.listHTML.isEmpty ? "NÃO" : "SIM (\(inputs.listHTML.count) caracteres)")")
        lines.append("HTML do detalhe presente? \(inputs.detailHTML.isEmpty ? "NÃO" : "SIM (\(inputs.detailHTML.count) caracteres)")")
        lines.append("HTML da página de vídeo presente? \(inputs.videoHTML.isEmpty ? "NÃO" : "SIM (\(inputs.videoHTML.count) caracteres)")")
        lines.append("")

        lines.append("== PAGINAÇÃO ==")
        lines.append("Forma: \(pagination.label)")
        lines.append("Página 1 canônica: \(pagination.page1Url.isEmpty ? "—" : pagination.page1Url)")
        lines.append("indexUrl final (no JSON): \(pagination.indexUrl.isEmpty ? "—" : pagination.indexUrl)")
        lines.append("")

        lines.append("== LISTA ==")
        if let list {
            lines.append("Seletor de item: \(list.itemSelector.isEmpty ? "(nenhum)" : list.itemSelector)")
            lines.append("Assinatura do bloco: \(list.itemSignature)")
            lines.append("Itens no bloco: \(list.itemCount)")
            if let f = list.titleField {
                lines.append("Título: \(f.summary) | estrito \(list.strictTitle) | exemplo: \(list.titleSample)")
            } else { lines.append("Título: não detectado") }
            if let f = list.coverField {
                lines.append("Capa: \(f.summary) | estrito \(list.strictCover) | exemplo: \(list.coverSample)")
            } else { lines.append("Capa: não detectada") }
            if let f = list.idCodeField {
                lines.append("idCode: \(f.summary) | estrito \(list.strictIdCode)")
                lines.append("URL do detalhe (item 1): \(list.idCodeSample)")
            } else { lines.append("idCode: não detectado") }
            for n in list.notes { lines.append("nota: \(n)") }
        } else {
            lines.append("(lista não analisada)")
        }
        lines.append("")

        lines.append("== DETALHE ==")
        if let detail {
            if let f = detail.titleField {
                lines.append("Título: \(f.summary) | exemplo: \(detail.titleSample)")
            } else { lines.append("Título: não detectado") }
            if let candidate = detail.coverCandidate {
                lines.append("Capa — candidato detectado: \(candidate.summary) | fonte: \(detail.coverSource)")
                lines.append("Capa — emissão no detailRule: selector \"this\" (lei da capa do detalhe) | valor: \(detail.coverSample)")
            } else { lines.append("Capa: não detectada — detalhe sai sem cover") }
            lines.append("og:description presente? \(detail.ogDescription != nil ? "SIM" : "NÃO")")
            if let itemSel = detail.tagItemSelector, detail.tagField != nil {
                lines.append("Tags: item \(itemSel) | \(detail.tagCount) links | exemplo: \(detail.tagSample)")
            } else { lines.append("Tags: nenhum sistema de tags detectado") }
            lines.append("")
            lines.append("VÍDEO — candidatos (\(detail.videos.count)):")
            for (i, v) in detail.videos.enumerated() {
                let mark = (chosenVideo?.finalURL == v.finalURL && chosenVideo?.family == v.family) ? " <<< ESCOLHIDO" : ""
                lines.append("  \(i + 1). [\(v.family)] (\(v.source)) | pontos: \(v.score)\(mark)")
                lines.append("     campo: \(v.field.summary)")
                lines.append("     URL final: \(v.finalURL)")
                if !v.note.isEmpty { lines.append("     nota: \(v.note)") }
            }
            if let video = chosenVideo {
                lines.append("Vídeo escolhido: [\(video.family)] \(video.finalURL)")
                lines.append("desc do detalhe = tupla do vídeo escolhido (conferência no app)")
            } else {
                lines.append("Vídeo escolhido: nenhum — detailRule sem videoRule")
            }
            for n in detail.notes { lines.append("nota: \(n)") }
        } else {
            lines.append("(detalhe não analisado)")
        }
        lines.append("")

        lines.append("== CATEGORIAS ==")
        let selected = categories.filter { $0.selected }
        lines.append("Grupo detectado: \(categories.count) links | marcadas: \(selected.count)")
        for (i, cat) in categories.enumerated() {
            lines.append("  \(i + 1). [\(cat.selected ? "x" : " ")] \(cat.name) → \(pagination.paginate(cat.url))")
        }
        return lines.joined(separator: "\n")
    }
}
