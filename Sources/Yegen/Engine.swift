import Foundation
import SwiftSoup

/// O motor do Yegen nativo — porta os contratos provados da versão web
/// (v3.27) de forma enxuta: análise da lista e do detalhe em modo estrito,
/// famílias núcleo de vídeo, paginação por comparação, categorias, tags e
/// a emissão do JSON na ordem canônica das rules do Yealico.
enum Engine {

    static let chainFunction = "html.regexReplacement.replace(\"\\/\", with: \"/\")"

    static func parse(_ html: String) -> Document? {
        guard !html.isEmpty else { return nil }
        return try? SwiftSoup.parse(html)
    }

    static func siteOrigin(_ inputs: YegenInputs) -> String {
        let base = !inputs.siteUrl.isEmpty ? inputs.siteUrl : inputs.indexUrl
        return HTMLKit.origin(of: base)
    }

    // MARK: - Preenchimento automático (a partir da URL da lista)

    /// Nome do site a partir do host: tira o "www" e capitaliza a primeira
    /// letra do domínio principal (meusite.com → "Meusite").
    static func deriveSiteName(from urlString: String) -> String? {
        var host = HTMLKit.host(of: urlString).lowercased()
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return nil }
        // TLDs de duas partes comuns (co.jp, com.br…): o nome é o rótulo anterior.
        let twoPartTLDs: Set<String> = ["co.jp", "com.br", "co.uk", "com.au",
                                        "co.kr", "ne.jp", "or.jp", "com.tw"]
        let suffix = labels.suffix(2).joined(separator: ".")
        let nameIndex = (labels.count >= 3 && twoPartTLDs.contains(suffix))
            ? labels.count - 3 : labels.count - 2
        let main = labels[nameIndex]
        guard let first = main.first else { return nil }
        return String(first).uppercased() + main.dropFirst()
    }

    /// URL inicial automática: a raiz do site (scheme + host + "/").
    static func deriveIndexURL(from urlString: String) -> String {
        let origin = HTMLKit.origin(of: urlString)
        return origin.isEmpty ? "" : origin + "/"
    }

    // MARK: - URL de busca automática (formulário no HTML da lista)

    /// Procura o formulário de busca da página (input type="search" ou com
    /// name em {s, q, keyword, search, query}) e monta a URL no padrão do
    /// site com {keyword}: query (?s={keyword}) ou caminho (/search/{keyword}),
    /// conforme a action do form. Sem formulário, retorna nil.
    static func detectSearchURL(doc: Document, origin: String, pageURL: String) -> String? {
        let searchNames: Set<String> = ["s", "q", "keyword", "search", "query"]
        for form in HTMLKit.select(doc, "form") {
            var paramName: String? = nil
            for input in HTMLKit.select(form, "input") {
                let name = input.attrOrEmpty("name")
                let type = input.attrOrEmpty("type").lowercased()
                if searchNames.contains(name.lowercased()) {
                    paramName = name
                    break
                }
                if type == "search" {
                    paramName = name.isEmpty ? "s" : name
                    break
                }
            }
            guard let param = paramName else { continue }

            let rawAction = form.attrOrEmpty("action")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            var base = (rawAction.isEmpty || rawAction.hasPrefix("#")
                        || rawAction.hasPrefix("javascript"))
                ? pageURL : HTMLKit.absolutize(rawAction, origin: origin)
            if let hash = base.firstIndex(of: "#") { base = String(base[..<hash]) }
            guard !base.isEmpty else { continue }

            if let q = base.firstIndex(of: "?") {
                // Já tem query: troca o valor do parâmetro ou acrescenta.
                let head = String(base[..<q])
                var pairs = String(base[base.index(after: q)...])
                    .split(separator: "&", omittingEmptySubsequences: true).map(String.init)
                if let i = pairs.firstIndex(where: {
                    $0.split(separator: "=", maxSplits: 1).first.map(String.init) == param
                }) {
                    pairs[i] = "\(param)={keyword}"
                } else {
                    pairs.append("\(param)={keyword}")
                }
                return head + "?" + pairs.joined(separator: "&")
            }
            // Sem query: action terminando em "search" → padrão de caminho.
            let lastSegment = base.split(separator: "/").last.map(String.init) ?? ""
            if lastSegment.lowercased() == "search" {
                return (base.hasSuffix("/") ? base : base + "/") + "{keyword}"
            }
            return base + "?\(param)={keyword}"
        }
        return nil
    }

    // MARK: - Utilidades

    /// Forma de uma URL com os números trocados por # (comparar rotas).
    static func shape(of url: String) -> String {
        guard let re = HTMLKit.regex(#"\d+"#) else { return url }
        return re.stringByReplacingMatches(
            in: url,
            range: NSRange(url.startIndex..., in: url),
            withTemplate: "#")
    }

    static func isAncestor(_ a: Element, of b: Element) -> Bool {
        var p = b.parent()
        while let cur = p {
            if cur === a { return true }
            p = cur.parent()
        }
        return false
    }

    static func pathPrefix(_ urlString: String) -> String {
        let comps = URL(string: urlString)?.pathComponents.filter { $0 != "/" } ?? []
        return comps.prefix(2).joined(separator: "/")
    }

    /// Normaliza uma URL pra página 1 (remove /page/N ou zera o parâmetro).
    static func normalizeToPage1(_ urlString: String) -> String {
        var u = urlString
        if let re = HTMLKit.regex(#"/page/\d+"#) {
            u = re.stringByReplacingMatches(
                in: u, range: NSRange(u.startIndex..., in: u), withTemplate: "")
        }
        if let re = HTMLKit.regex(#"([?&]page=)(\d+)"#),
           let m = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)),
           let vr = Range(m.range(at: 2), in: u) {
            u.replaceSubrange(vr, with: "1")
        }
        return u
    }

    static func strictRatio(_ ok: Int, of total: Int) -> Bool {
        guard total > 0 else { return false }
        return ok >= max(1, Int(ceil(0.75 * Double(total))))
    }

    // MARK: - Paginação (motor de comparação: o que muda é a variável)

    static func detectPagination(inputs: YegenInputs) -> PaginationInfo {
        var info = PaginationInfo()
        let raw = !inputs.siteUrl.isEmpty ? inputs.siteUrl : inputs.indexUrl
        guard !raw.isEmpty else { return info }

        // Forma 1: /page/N no caminho (MacCMS: /page/2.html)
        if let re = HTMLKit.regex(#"/page/(\d+)"#),
           let m = re.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
           let r = Range(m.range, in: raw) {
            info.kind = .pageFormat
            info.core = "/page/{page:}"
            var page1 = raw
            page1.removeSubrange(r)   // some o "/page/2"; o ".html" fica
            info.page1Url = page1
            info.indexUrl = info.paginate(page1)
            info.label = "pageFormat — /page/{page:} (da URL colada)"
            return info
        }

        // Forma 2: parâmetro de query (?page=2, ?p=3…)
        if let re = HTMLKit.regex(#"[?&]([A-Za-z_][A-Za-z0-9_]*)=(\d+)"#) {
            let matches = re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw))
            var chosen: NSTextCheckingResult? = nil
            for m in matches {
                if let nr = Range(m.range(at: 1), in: raw), raw[nr] == "page" { chosen = m; break }
            }
            if chosen == nil {
                chosen = matches.first(where: { m in
                    guard let vr = Range(m.range(at: 2), in: raw) else { return false }
                    return (Int(raw[vr]) ?? 0) >= 2
                }) ?? matches.first
            }
            if let m = chosen,
               let nr = Range(m.range(at: 1), in: raw),
               let vr = Range(m.range(at: 2), in: raw) {
                let name = String(raw[nr])
                info.kind = .queryDirect
                info.paramName = name
                var page1 = raw
                page1.replaceSubrange(vr, with: "1")
                info.page1Url = page1
                // Base sem o parâmetro de página: o paginate recoloca {page:}
                var base = raw
                if let full = Range(m.range, in: raw) {
                    base.removeSubrange(full)
                    if base.hasSuffix("?") || base.hasSuffix("&") {
                        base.removeLast()
                    }
                    base = base.replacingOccurrences(of: "?&", with: "?")
                }
                info.indexUrl = info.paginate(base)
                info.label = "query direta — ?\(name)={page:}"
                return info
            }
        }

        info.page1Url = raw
        info.indexUrl = raw
        info.label = "sem paginação detectada na URL"
        return info
    }

    // MARK: - Análise da LISTA

    static func analyzeList(inputs: YegenInputs) -> ListAnalysis? {
        guard let doc = parse(inputs.listHTML) else { return nil }
        var result = ListAnalysis()
        let origin = siteOrigin(inputs)
        let structural: Set<String> = ["html", "head", "body", "script", "style",
                                       "meta", "link", "title", "noscript", "br"]
        let all = ((try? doc.getAllElements())?.array() ?? []).filter { !structural.contains($0.tagName()) }

        // Blocos repetidos: mesma assinatura (tag+classes) sob o mesmo pai.
        var groups: [String: [Element]] = [:]
        for el in all {
            let parentKey = el.parent().map { HTMLKit.signature($0) } ?? "-"
            groups[HTMLKit.signature(el) + "|" + parentKey, default: []].append(el)
        }
        let ranked = groups.values.filter { $0.count >= 3 }.sorted { $0.count > $1.count }
        var items: [Element] = []
        for group in ranked {
            // Fora os ancestrais de outros membros (cadeia de embrulho).
            // Passada única: subindo de cada membro, marca os ancestrais que
            // também estão no grupo (sem comparações par a par — era O(n²)).
            let groupIDs = Set(group.map { ObjectIdentifier($0) })
            var wrapped = Set<ObjectIdentifier>()
            for el in group {
                var ancestor = el.parent()
                while let current = ancestor {
                    if groupIDs.contains(ObjectIdentifier(current)) {
                        wrapped.insert(ObjectIdentifier(current))
                    }
                    ancestor = current.parent()
                }
            }
            let flat = group.filter { !wrapped.contains(ObjectIdentifier($0)) }
            guard flat.count >= 3, let first = flat.first,
                  !HTMLKit.select(first, "a, img").isEmpty else { continue }
            items = flat
            break
        }
        guard let firstItem = items.first else {
            result.notes.append("nenhum bloco repetido com 3+ itens foi encontrado no HTML da lista")
            return result
        }
        result.itemSignature = HTMLKit.signature(firstItem)
        result.itemSelector = HTMLKit.selector(forSignature: result.itemSignature)
        result.itemCount = items.count
        let sample = Array(items.prefix(8))

        // ---- Título
        result.titleField = detectTitle(in: firstItem, sample: sample, result: &result)
        // ---- Capa
        result.coverField = detectCover(in: firstItem, sample: sample, result: &result)
        // ---- idCode (lei do seletor mínimo: 'a' simples primeiro)
        result.idCodeField = detectIdCode(in: firstItem, sample: sample, origin: origin, result: &result)

        if result.titleField == nil { result.notes.append("título não passou no teste estrito") }
        if result.coverField == nil { result.notes.append("capa não passou no teste estrito") }
        if result.idCodeField == nil { result.notes.append("idCode não passou no teste estrito") }
        return result
    }

    private static func detectTitle(in item: Element, sample: [Element],
                                    result: inout ListAnalysis) -> FieldRule? {
        let descendants = ((try? item.getAllElements())?.array() ?? []).filter { $0 !== item }
        var candidates: [(target: Element, function: String, param: String?)] = []
        for el in descendants where el.tagName() == "a" && !el.attrOrEmpty("title").isEmpty {
            candidates.append((el, "attr", "title"))
        }
        for el in descendants where ["h1", "h2", "h3", "h4"].contains(el.tagName()) {
            candidates.append((el, "text", nil))
        }
        for el in descendants where el.classNamesOrEmpty().contains(where: { $0.lowercased().contains("title") }) {
            candidates.append((el, "text", nil))
        }
        for el in descendants where el.tagName() == "a" {
            candidates.append((el, "text", nil))
        }
        var seen = Set<String>()
        for cand in candidates {
            let selector = HTMLKit.relativeSelector(item: item, target: cand.target)
            let key = selector + "|" + cand.function + "|" + (cand.param ?? "")
            guard seen.insert(key).inserted else { continue }
            let field = FieldRule(selector: selector, function: cand.function, param: cand.param)
            var ok = 0
            var firstValue = ""
            for (i, it) in sample.enumerated() {
                if let v = HTMLKit.extract(field, in: it), v.count >= 2 {
                    ok += 1
                    if i == 0 { firstValue = v }
                }
            }
            if strictRatio(ok, of: sample.count) {
                result.strictTitle = "\(ok)/\(sample.count)"
                result.titleSample = firstValue
                return field
            }
        }
        return nil
    }

    private static func detectCover(in item: Element, sample: [Element],
                                    result: inout ListAnalysis) -> FieldRule? {
        guard let img = HTMLKit.select(item, "img").first else { return nil }
        let param: String
        if !img.attrOrEmpty("data-src").isEmpty { param = "data-src, src" }
        else if !img.attrOrEmpty("data-original").isEmpty { param = "data-original, src" }
        else if !img.attrOrEmpty("data-lazy-src").isEmpty { param = "data-lazy-src, src" }
        else { param = "src" }
        let field = FieldRule(selector: HTMLKit.relativeSelector(item: item, target: img),
                              function: "attr", param: param,
                              regex: "(.+)", replacement: "$1")
        var ok = 0
        var firstValue = ""
        for (i, it) in sample.enumerated() {
            if let v = HTMLKit.extract(field, in: it), isImageURL(v) {
                ok += 1
                if i == 0 { firstValue = v }
            }
        }
        guard strictRatio(ok, of: sample.count) else { return nil }
        result.strictCover = "\(ok)/\(sample.count)"
        result.coverSample = firstValue
        return field
    }

    static func isImageURL(_ v: String) -> Bool {
        guard !v.hasPrefix("data:") else { return false }
        guard v.hasPrefix("http://") || v.hasPrefix("https://") || v.hasPrefix("/") else { return false }
        return v.count > 10 && !v.contains(" ")
    }

    private static func detectIdCode(in item: Element, sample: [Element], origin: String,
                                     result: inout ListAnalysis) -> FieldRule? {
        let anchors = HTMLKit.select(item, "a").filter { a in
            let h = a.attrOrEmpty("href")
            return !h.isEmpty && !h.hasPrefix("#") && !h.hasPrefix("javascript")
        }
        guard let firstAnchor = anchors.first else { return nil }
        var selectorOptions: [String] = ["a"]
        let rel = HTMLKit.relativeSelector(item: item, target: firstAnchor)
        if rel != "a" { selectorOptions.append(rel) }

        for selector in selectorOptions {
            let probeField = FieldRule(selector: selector, function: "attr", param: "href")
            guard let href0 = HTMLKit.extract(probeField, in: item) else { continue }
            let regex: String
            let replacement: String
            if href0.hasPrefix("http://") || href0.hasPrefix("https://") {
                regex = "(.+)"; replacement = "$1"
            } else if href0.hasPrefix("/") {
                regex = "(.+)"; replacement = origin + "$1"
            } else {
                regex = "(.+)"; replacement = origin + "/$1"
            }
            let field = FieldRule(selector: selector, function: "attr", param: "href",
                                  regex: regex, replacement: replacement)
            var ok = 0
            var shapes = Set<String>()
            var urls: [String] = []
            for it in sample {
                if let v = HTMLKit.extract(field, in: it) {
                    ok += 1
                    shapes.insert(shape(of: v))
                    urls.append(v)
                }
            }
            if strictRatio(ok, of: sample.count), shapes.count == 1 {
                result.strictIdCode = "\(ok)/\(sample.count)"
                result.idCodeSample = urls.first ?? ""
                result.detailSamples = urls
                return field
            }
        }
        return nil
    }

    // MARK: - Análise do DETALHE

    static func analyzeDetail(inputs: YegenInputs, list: ListAnalysis?) -> DetailAnalysis? {
        guard let doc = parse(inputs.detailHTML) else { return nil }
        var result = DetailAnalysis()
        let origin = siteOrigin(inputs)

        // ---- Título: h1 da página > og:title
        if let h1 = HTMLKit.select(doc, "h1").first(where: { !$0.textOrEmpty().isEmpty }) {
            let field = FieldRule(selector: HTMLKit.shortSelector(h1), function: "text")
            result.titleField = field
            result.titleSample = HTMLKit.extract(field, in: doc) ?? h1.textOrEmpty()
        } else if let ogTitle = HTMLKit.metaContent(doc, property: "og:title") {
            result.titleField = FieldRule(selector: "meta[property=\"og:title\"]",
                                          function: "attr", param: "content")
            result.titleSample = ogTitle
        } else {
            result.notes.append("sem h1 e sem og:title no detalhe")
        }

        // ---- Capa: og:image > fallback (imagem de conteúdo fora dos blocos da lista)
        if let ogImage = HTMLKit.metaContent(doc, property: "og:image") {
            result.coverCandidate = FieldRule(selector: "meta[property=\"og:image\"]",
                                              function: "attr", param: "content")
            result.coverSample = HTMLKit.absolutize(ogImage, origin: origin)
            result.coverSource = "og:image"
        } else {
            let itemSig = list?.itemSignature ?? ""
            let imgs = HTMLKit.select(doc, "img").filter { img in
                if !itemSig.isEmpty {
                    var p = img.parent()
                    while let cur = p {
                        if HTMLKit.signature(cur) == itemSig { return false }
                        p = cur.parent()
                    }
                }
                var p = img.parent()
                while let cur = p {
                    if ["header", "footer", "nav"].contains(cur.tagName()) { return false }
                    p = cur.parent()
                }
                return true
            }
            let usable = imgs.first(where: { img in
                let src = !img.attrOrEmpty("data-src").isEmpty ? img.attrOrEmpty("data-src") : img.attrOrEmpty("src")
                let bad = ["logo", "icon", "sprite", "avatar", "banner", "loading"]
                return isImageURL(src) && !bad.contains(where: { src.lowercased().contains($0) })
            }) ?? imgs.first
            if let img = usable {
                let param: String
                if !img.attrOrEmpty("data-src").isEmpty { param = "data-src, src" }
                else if !img.attrOrEmpty("data-original").isEmpty { param = "data-original, src" }
                else { param = "src" }
                let field = FieldRule(selector: HTMLKit.relativeSelector(item: doc, target: img),
                                      function: "attr", param: param,
                                      regex: "(.+)", replacement: "$1")
                result.coverCandidate = field
                if let v = HTMLKit.extract(field, in: doc) {
                    result.coverSample = HTMLKit.absolutize(v, origin: origin)
                }
                result.coverSource = "fallback (imagem de conteúdo)"
            } else {
                result.notes.append("sem og:image e sem imagem de conteúdo utilizável — detalhe sai sem cover")
            }
        }

        result.ogDescription = HTMLKit.metaContent(doc, property: "og:description")

        // ---- Vídeo: famílias núcleo no detalhe + na página de vídeo
        var videos = videoCandidates(raw: inputs.detailHTML, doc: doc, origin: origin,
                                     source: "detalhe", coverSample: result.coverSample)
        if !inputs.videoHTML.isEmpty, let vdoc = parse(inputs.videoHTML) {
            videos += videoCandidates(raw: inputs.videoHTML, doc: vdoc, origin: origin,
                                      source: "página de vídeo", coverSample: result.coverSample)
        }
        var bestByURL: [String: VideoCandidate] = [:]
        for v in videos {
            if let cur = bestByURL[v.finalURL], cur.score >= v.score { continue }
            bestByURL[v.finalURL] = v
        }
        result.videos = bestByURL.values.sorted { $0.score > $1.score }
        if result.videos.isEmpty {
            result.notes.append("nenhum candidato de vídeo confirmado no HTML cru")
        }

        // ---- Tags
        detectTags(doc: doc, list: list, origin: origin, result: &result)
        return result
    }

    // MARK: - Varredura rápida de URLs de mídia no corpo cru
    //
    // As regexes de corpo inteiro com prefixo lazy ([\s\S]*? …) portadas do
    // motor JS causavam backtracking pesado no NSRegularExpression sobre o
    // HTML inteiro (minutos de "Analisando…"). A detecção agora é em duas
    // fases, com o MESMO resultado: (1) busca simples de string localiza as
    // ocorrências dos marcadores; (2) uma regex curta, ancorada e limitada à
    // vizinhança da ocorrência (janela), extrai e valida a URL candidata —
    // incluindo as formas com barras escapadas (https?:\?/\?/) das receitas
    // provadas do guia. Os FieldRule emitidos pras famílias não mudam: só a
    // forma de ACHAR a URL no app é que ficou rápida.

    /// Desescapa "\/" → "/" (a cadeia do guia) no resultado extraído.
    private static func unescapeSlashes(_ url: String) -> String {
        url.replacingOccurrences(of: "\\/", with: "/")
    }

    /// Primeira URL .m3u8/.mp4 do corpo. scriptMode = família Script/JSON
    /// (a alternativa "index." encerra a captura logo após a extensão);
    /// fora dele, vale a família de corpo (captura vai até a aspa).
    private static func firstMediaURL(in raw: String, scriptMode: Bool) -> String? {
        let pattern = scriptMode
            ? #"^(https?:\?/\?/[^"]+?(?:index\.(?:m3u8|mp4)|\.(?:m3u8|mp4)[^"]*))"#
            : #"^(https?:\?/\?/[^"]+?\.(?:m3u8|mp4)[^"]*)"#
        var searchStart = raw.startIndex
        while let hit = raw.range(of: "http", range: searchStart..<raw.endIndex) {
            let windowEnd = raw.index(hit.lowerBound, offsetBy: 2048,
                                      limitedBy: raw.endIndex) ?? raw.endIndex
            let window = String(raw[hit.lowerBound..<windowEnd])
            if let captured = HTMLKit.firstCapture(pattern, in: window, replacement: "$1") {
                return unescapeSlashes(captured)
            }
            searchStart = raw.index(after: hit.lowerBound)
        }
        return nil
    }

    /// URL da config MacCMS (player_aaaa): localiza o marcador e procura o
    /// par "url": "…" numa janela curta a partir dele.
    private static func macCMSPlayerURL(in raw: String) -> String? {
        let pattern = #""url"\s*:\s*"(https?:\?/\?/[^"]+?\.(?:m3u8|mp4)[^"]*)""#
        var searchStart = raw.startIndex
        while let hit = raw.range(of: "player_aaaa", range: searchStart..<raw.endIndex) {
            let windowEnd = raw.index(hit.lowerBound, offsetBy: 8192,
                                      limitedBy: raw.endIndex) ?? raw.endIndex
            let window = String(raw[hit.lowerBound..<windowEnd])
            if let captured = HTMLKit.firstCapture(pattern, in: window, replacement: "$1") {
                return unescapeSlashes(captured)
            }
            searchStart = raw.index(after: hit.lowerBound)
        }
        return nil
    }

    private static func videoCandidates(raw: String, doc: Document, origin: String,
                                        source: String, coverSample: String) -> [VideoCandidate] {
        var out: [VideoCandidate] = []
        func add(family: String, field: FieldRule, url: String?, score: Int, note: String = "") {
            guard let url, !url.isEmpty else { return }
            var s = score
            var n = note
            if !coverSample.isEmpty && url == coverSample {
                s -= 1000
                n = "igual à capa do detalhe (provável pôster, não stream)"
            }
            if url.contains("/plain/rs:fit:") {
                s -= 1000
                n = "URL de pipeline de thumbnail (/plain/rs:fit:) — pôster, não stream"
            }
            out.append(VideoCandidate(family: family, field: field, finalURL: url,
                                      score: s, source: source, note: n))
        }

        // 1) Config MacCMS player_aaaa — a "url" da config do player
        let macField = FieldRule(
            selector: "body", function: chainFunction,
            regex: #"player_aaaa\s*=\s*\{[\s\S]*?"url"\s*:\s*"(https?:\?/\?/[^"]+?\.(?:m3u8|mp4)[^"]*)""#,
            replacement: "$1")
        add(family: "MacCMS (player_aaaa)", field: macField,
            url: macCMSPlayerURL(in: raw), score: 495)

        // 2) Script/JSON unificado (guia) — .m3u8/.mp4 escapado em script/config
        let scriptField = FieldRule(
            selector: "body", function: chainFunction,
            regex: #"[\s\S]*?(https?:\?/\?/[^"]+?(?:index\.(?:m3u8|mp4)|\.(?:m3u8|mp4)[^"]*))[\s\S]*"#,
            replacement: "$1")
        add(family: "Script/JSON .m3u8/.mp4 unificado (guia)", field: scriptField,
            url: firstMediaURL(in: raw, scriptMode: true), score: 70)

        // 3) Corpo unificado (guia)
        let bodyField = FieldRule(
            selector: "body", function: chainFunction,
            regex: #"[\s\S]*?(https?:\?/\?/[^"]+?\.(?:m3u8|mp4)[^"]*)[\s\S]*"#,
            replacement: "$1")
        add(family: ".m3u8/.mp4 unificado no corpo (guia)", field: bodyField,
            url: firstMediaURL(in: raw, scriptMode: false), score: 70)

        // 4) Guia: iframe com url= no src
        let iframeField = FieldRule(
            selector: "body",
            regex: #"src="[^"]*?url=([^"]+)""#,
            replacement: "$1")
        add(family: "Iframe url= (guia)", field: iframeField,
            url: HTMLKit.applyBodyField(iframeField, rawText: raw), score: 65)

        // 5) og:video
        if let ogVideo = HTMLKit.metaContent(doc, property: "og:video")
            ?? HTMLKit.metaContent(doc, property: "og:video:url") {
            let field = FieldRule(selector: "meta[property=\"og:video\"]",
                                  function: "attr", param: "content")
            add(family: "og:video", field: field, url: ogVideo, score: 320)
        }

        // 6) <video>/<source> no DOM
        for el in HTMLKit.select(doc, "video, source") {
            let src = el.attrOrEmpty("src")
            guard src.contains(".mp4") || src.contains(".m3u8") else { continue }
            let field = FieldRule(selector: HTMLKit.relativeSelector(item: doc, target: el),
                                  function: "attr", param: "src")
            add(family: "Elemento <video>/<source>", field: field,
                url: HTMLKit.absolutize(src, origin: origin), score: 260)
            break
        }
        return out
    }

    private static func detectTags(doc: Document, list: ListAnalysis?, origin: String,
                                   result: inout DetailAnalysis) {
        let detailShape = list.map { shape(of: $0.idCodeSample) } ?? ""
        var groups: [String: [Element]] = [:]
        for a in HTMLKit.select(doc, "a") {
            let href = a.attrOrEmpty("href")
            guard !href.isEmpty, !href.hasPrefix("#"), !href.hasPrefix("javascript") else { continue }
            let key = a.parent().map { HTMLKit.signature($0) } ?? a.tagName()
            groups[key, default: []].append(a)
        }
        var bestGroup: [Element] = []
        var bestScore = -1
        for (_, g) in groups where g.count >= 2 && g.count <= 30 {
            let valid = g.filter { a in
                let text = a.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 30 else { return false }
                let abs = HTMLKit.absolutize(a.attrOrEmpty("href"), origin: origin)
                if !detailShape.isEmpty && shape(of: abs) == detailShape { return false }
                return true
            }
            guard valid.count >= 2 else { continue }
            var score = valid.count
            var p = valid.first?.parent()
            var depth = 0
            while let cur = p, depth < 3 {
                let marker = (cur.attrOrEmpty("class") + " " + cur.attrOrEmpty("id")).lowercased()
                if marker.contains("tag") { score += 20; break }
                p = cur.parent()
                depth += 1
            }
            if score > bestScore { bestScore = score; bestGroup = valid }
        }
        guard let first = bestGroup.first else { return }
        let anchorSig = HTMLKit.signature(first)
        let itemSelector: String
        if anchorSig != "a" {
            itemSelector = HTMLKit.selector(forSignature: anchorSig)
        } else if let parent = first.parent(), parent.tagName() != "body" {
            itemSelector = parent.tagName() + " a"
        } else {
            itemSelector = "a"
        }
        let href0 = first.attrOrEmpty("href")
        let regex: String
        let replacement: String
        if href0.hasPrefix("http://") || href0.hasPrefix("https://") {
            regex = "(.+)"; replacement = "$1"
        } else if href0.hasSuffix(".html") {
            regex = #"(.+)\.html"#; replacement = origin + "$1" + "{pageFormat:/page/{page:}}.html"
        } else if href0.hasPrefix("/") {
            regex = "(.+)"; replacement = origin + "$1"
        } else {
            regex = "(.+)"; replacement = origin + "/$1"
        }
        result.tagItemSelector = itemSelector
        result.tagField = FieldRule(selector: "this", function: "attr", param: "href",
                                    regex: regex, replacement: replacement)
        result.tagCount = bestGroup.count
        result.tagSample = first.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Categorias (grupo de links da página de lista)

    static func detectCategories(doc: Document, list: ListAnalysis?, origin: String) -> [CategoryLink] {
        let detailShapes = Set((list?.detailSamples ?? []).map { shape(of: $0) })
        var groups: [String: [Element]] = [:]
        for a in HTMLKit.select(doc, "a") {
            let href = a.attrOrEmpty("href")
            guard !href.isEmpty, !href.hasPrefix("#"), !href.hasPrefix("javascript") else { continue }
            let key = a.parent().map { HTMLKit.signature($0) } ?? a.tagName()
            groups[key, default: []].append(a)
        }
        var best: [CategoryLink] = []
        var bestScore = 0.0
        for (_, g) in groups where g.count >= 3 {
            var links: [CategoryLink] = []
            var seen = Set<String>()
            for a in g {
                let text = a.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, text.count <= 60 else { continue }
                let abs = HTMLKit.absolutize(a.attrOrEmpty("href"), origin: origin)
                if !origin.isEmpty && HTMLKit.host(of: abs) != HTMLKit.host(of: origin) { continue }
                if detailShapes.contains(shape(of: abs)) { continue }   // grupo = itens, não categorias
                if abs == origin || abs == origin + "/" { continue }
                guard seen.insert(abs).inserted else { continue }
                links.append(CategoryLink(name: text, url: normalizeToPage1(abs)))
            }
            guard links.count >= 3 else { continue }
            let prefixes = links.map { pathPrefix($0.url) }
            let dominant = Dictionary(grouping: prefixes, by: { $0 }).values.map { $0.count }.max() ?? 0
            let coherence = Double(dominant) / Double(links.count)
            let score = Double(links.count) * coherence
            if coherence >= 0.6 && score > bestScore {
                bestScore = score
                best = links
            }
        }
        return best
    }

    // MARK: - Emissão do JSON da rule

    /// Capa do detalhe como entra no JSON: selector "this" (lei dele),
    /// mantendo function/param/regex/replacement do candidato detectado.
    static func emittedDetailCover(_ detail: DetailAnalysis) -> FieldRule? {
        guard let c = detail.coverCandidate else { return nil }
        return FieldRule(selector: "this", function: c.function, param: c.param,
                         regex: c.regex, replacement: c.replacement)
    }

    static func buildRule(inputs: YegenInputs, list: ListAnalysis?, detail: DetailAnalysis?,
                          categories: [CategoryLink], pagination: PaginationInfo,
                          chosenVideo: VideoCandidate?, searchUrl: String) -> JVal {
        let origin = siteOrigin(inputs)
        var root: [(String, JVal)] = []
        root.append(("name", .str(inputs.ruleName.isEmpty ? "Sem nome" : inputs.ruleName)))
        root.append(("version", .str("1.0")))
        root.append(("isEditable", .bool(true)))
        root.append(("isEncrypted", .bool(false)))
        root.append(("domain", .str(origin)))
        root.append(("displayMode", .str("collection")))

        // headers: Referer quando o stream mora em outro host
        if let video = chosenVideo, !origin.isEmpty,
           !HTMLKit.host(of: video.finalURL).isEmpty,
           HTMLKit.host(of: video.finalURL) != HTMLKit.host(of: origin) {
            root.append(("headers", .obj([("Referer", .str(origin + "/"))])))
        }

        let indexUrl = pagination.indexUrl.isEmpty
            ? normalizeToPage1(!inputs.siteUrl.isEmpty ? inputs.siteUrl : inputs.indexUrl)
            : pagination.indexUrl
        root.append(("indexUrl", .str(indexUrl)))
        root.append(("detailUrl", .str("{idCode:}")))
        // A busca é automática: derivada do formulário no HTML da lista.
        let hasSearch = !searchUrl.isEmpty
        if hasSearch { root.append(("searchUrl", .str(searchUrl))) }

        // indexRule / searchRule
        if let list, !list.itemSelector.isEmpty {
            let itemSel = list.itemSelector
            var rulePairs: [(String, JVal)] = [("item", .obj([("selector", .str(itemSel))]))]
            if let f = list.titleField { rulePairs.append(("title", f.jval)) }
            if let f = list.coverField { rulePairs.append(("cover", f.jval)) }
            if let f = list.idCodeField { rulePairs.append(("idCode", f.jval)) }
            root.append(("indexRule", .obj(rulePairs)))
            if hasSearch { root.append(("searchRule", .obj(rulePairs))) }
        }

        // detailRule
        if let detail {
            var pairs: [(String, JVal)] = []
            if let f = detail.titleField { pairs.append(("title", f.jval)) }
            let cover = emittedDetailCover(detail)
            if let cover { pairs.append(("cover", cover.jval)) }
            // desc: espelho do vídeo escolhido (conferência); sem vídeo, og:description
            if let video = chosenVideo {
                pairs.append(("desc", video.field.jval))
            } else if detail.ogDescription != nil {
                pairs.append(("desc", FieldRule(selector: "meta[property=\"og:description\"]",
                                                function: "attr", param: "content").jval))
            }
            if let itemSel = detail.tagItemSelector, let urlField = detail.tagField {
                let tagRule = JVal.obj([
                    ("item", .obj([("selector", .str(itemSel))])),
                    ("name", FieldRule(selector: "this", function: "text").jval),
                    ("url", urlField.jval)
                ])
                pairs.append(("tagRule", tagRule))
            }
            if let video = chosenVideo {
                var videoPairs: [(String, JVal)] = [("item", .obj([("selector", .str("html"))]))]
                if let f = detail.titleField { videoPairs.append(("title", f.jval)) }
                if let cover { videoPairs.append(("cover", cover.jval)) }
                videoPairs.append(("url", video.field.jval))
                pairs.append(("videoRule", .obj(videoPairs)))
            }
            root.append(("detailRule", .obj(pairs)))

            // tagSearchRule na raiz (mesma estrutura do tagRule do detalhe)
            if let itemSel = detail.tagItemSelector, let urlField = detail.tagField {
                root.append(("tagSearchRule", .obj([
                    ("item", .obj([("selector", .str(itemSel))])),
                    ("name", FieldRule(selector: "this", function: "text").jval),
                    ("url", urlField.jval)
                ])))
            }
        }

        // pages: Início + categorias marcadas
        var pages: [JVal] = [
            .obj([("name", .str("Início")), ("listUrl", .str(indexUrl)),
                  ("displayMode", .str("collection")), ("flags", .str("default")),
                  ("index", .int(0))])
        ]
        var idx = 1
        for cat in categories where cat.selected {
            pages.append(.obj([("name", .str(cat.name)),
                               ("listUrl", .str(pagination.paginate(cat.url))),
                               ("displayMode", .str("collection")),
                               ("flags", .str("default")),
                               ("index", .int(idx))]))
            idx += 1
        }
        root.append(("pages", .arr(pages)))
        return .obj(root)
    }
}
