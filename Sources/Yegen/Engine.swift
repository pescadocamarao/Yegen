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

    // MARK: - Análise da LISTA (porte fiel do motor web v3.28 — v1.1)
    //
    // Substitui a simplificação antiga (grupo por assinatura sob o mesmo
    // pai, primeiro grupo com link vence — que degenerava pro seletor
    // "a" com todos os links da página) pela lógica do web, função por
    // função: agrupamento por assinatura em todo o documento + passo de
    // FAMÍLIA (v3.13), resgate semântico (v3.7), seletor robusto (v1.8),
    // detector de blocos estruturais, padrão item-âncora (v2.0.4),
    // pontuação com lealdade ao domínio/clique/semântica/lateralidade
    // (v3.7), guardas anti-pseudo-item (v3.11), portão de pré-seleção
    // (v3.7), estabilização de campos (v3.14), lei do seletor mínimo do
    // idCode (v3.15) e face lazy (v3.8). Desvios estruturais assumidos
    // estão marcados com "DESVIO" nos comentários.

    // MARK: Tipos internos do porte

    private struct TitleRes {
        var selector: String
        var function: String
        var param: String?
        var sample: String
        var field: FieldRule { FieldRule(selector: selector, function: function, param: param) }
    }

    private struct CoverRes {
        var selector: String
        var attr: String
        var param: String
        var rawValue: String
        var value: String
        var regex: String
        var replacement: String
        var lazy: Bool
        var bestEl: Element?
        var field: FieldRule {
            FieldRule(selector: selector, function: "attr", param: param,
                      regex: regex, replacement: replacement)
        }
    }

    private struct IdRes {
        var selector: String
        var regex: String
        var replacement: String
        var sample: String       // href cru
        var finalUrl: String     // href após a transformação
        var field: FieldRule {
            FieldRule(selector: selector, function: "attr", param: "href",
                      regex: regex, replacement: replacement)
        }
    }

    private final class BlockGroup {
        var selector: String
        var els: [Element]
        var isBlock = false
        var isAnchorItem = false
        var statsPct: (cover: Int, title: Int, link: Int)? = nil
        var title: TitleRes? = nil
        var cover: CoverRes? = nil
        var idc: IdRes? = nil
        var score = 0
        // medições v3.7 (portão e notas leem daqui)
        var clickPass = 0
        var clickTotal = 0
        var clickPasses = false
        var blogroll = false
        var isLateral = false
        var guardNotes: [String] = []
        init(selector: String, els: [Element]) {
            self.selector = selector
            self.els = els
        }
    }

    /// Contexto de uma análise: documento, origem e o exemplo de
    /// detalhe (a URL que ele digitou) + memos do trio caro
    /// (capa/título/idCode), como o web (WeakMap zerado por análise).
    private final class TrioCtx {
        let origin: String
        let exampleResolved: String   // URL do detalhe-exemplo resolvida ("" se não há)
        let exampleSegs: [String]
        private var titleMemo: [ObjectIdentifier: TitleRes?] = [:]
        private var titleMiss = Set<ObjectIdentifier>()
        private var coverMemo: [ObjectIdentifier: CoverRes?] = [:]
        private var coverMiss = Set<ObjectIdentifier>()
        private var idMemo: [ObjectIdentifier: IdRes?] = [:]
        private var idMiss = Set<ObjectIdentifier>()

        init(origin: String, detailExampleUrl: String) {
            self.origin = origin
            if detailExampleUrl.isEmpty {
                exampleResolved = ""
                exampleSegs = []
            } else {
                let resolved = HTMLKit.absolutize(detailExampleUrl, origin: origin)
                exampleResolved = resolved
                exampleSegs = TrioCtx.pathSegments(of: resolved)
            }
        }

        static func pathSegments(of urlString: String) -> [String] {
            guard let path = URL(string: urlString)?.path else { return [] }
            return path.split(separator: "/").map(String.init)
        }

        func title(_ item: Element) -> TitleRes? {
            let key = ObjectIdentifier(item)
            if let hit = titleMemo[key] { return hit }
            if titleMiss.contains(key) { return nil }
            let r = Engine.suggestTitleRaw(item, ctx: self)
            if let r { titleMemo[key] = r } else { titleMiss.insert(key) }
            return r
        }

        func cover(_ item: Element) -> CoverRes? {
            let key = ObjectIdentifier(item)
            if let hit = coverMemo[key] { return hit }
            if coverMiss.contains(key) { return nil }
            let r = Engine.detectCoverInItemRaw(item)
            if let r { coverMemo[key] = r } else { coverMiss.insert(key) }
            return r
        }

        func idCode(_ item: Element) -> IdRes? {
            let key = ObjectIdentifier(item)
            if let hit = idMemo[key] { return hit }
            if idMiss.contains(key) { return nil }
            let r = Engine.suggestIdCodeRaw(item, ctx: self)
            if let r { idMemo[key] = r } else { idMiss.insert(key) }
            return r
        }
    }

    // MARK: Utilidades de capa (web: classify/placeholder/templates)

    static func isPlaceholderSrc(_ v: String?) -> Bool {
        guard let v else { return true }
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return true }
        if t.hasPrefix("data:") { return true }
        return t.range(of: #"1x1|blank|placeholder|transparent|spacer|loading\.|grey\.|gray\.|no[-_ ]?image"#,
                       options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func hasImageExt(_ v: String) -> Bool {
        v.range(of: #"\.(webp|png|jpe?g|gif|avif)(\?|#|$)"#,
                options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func looksLikeImageUrl(_ v: String?) -> Bool {
        guard let v else { return false }
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("data:") { return false }
        return hasImageExt(t) || t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("/")
    }

    /// classifyCoverValue do web: strong / probable / placeholder / none.
    static func classifyCoverValue(_ v: String?) -> String {
        guard let v else { return "none" }
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "none" }
        if isPlaceholderSrc(t) { return "placeholder" }
        if t.range(of: #"\.mp4/plain/"#, options: [.regularExpression, .caseInsensitive]) != nil
            || t.range(of: #"/plain/rs:"#, options: .caseInsensitive) != nil { return "strong" }
        if hasImageExt(t) { return "strong" }
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("//") || t.hasPrefix("/") { return "probable" }
        return "none"
    }

    static func parseSrcsetLargest(_ v: String) -> String {
        let parts = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var best = ""
        var bestW = -1.0
        for part in parts {
            let toks = part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard let url = toks.first else { continue }
            var w = 0.0
            if toks.count > 1 {
                let d = toks[1]
                if d.hasSuffix("w") { w = Double(d.dropLast()) ?? 0 }
                else if d.hasSuffix("x") { w = (Double(d.dropLast()) ?? 0) * 1000 }
            }
            if w > bestW { bestW = w; best = url }
        }
        if !best.isEmpty { return best }
        return parts.first?.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
    }

    static func extractBgUrl(_ style: String) -> String? {
        if let v = HTMLKit.firstCapture(#"background-image\s*:\s*url\(\s*["']?([^"')]+)["']?\s*\)"#,
                                        in: style, replacement: "$1") { return v }
        return HTMLKit.firstCapture(#"url\(\s*["']?([^"')]+)["']?\s*\)"#, in: style, replacement: "$1")
    }

    static func isCleanCoverUrl(_ v: String) -> Bool {
        let t = v.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.contains("url(") || t.contains(",") || t.contains(" ") || t.contains("&amp;") { return false }
        if isPlaceholderSrc(t) { return false }
        return t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("//") || t.hasPrefix("/")
    }

    private struct CoverTemplate { let id: String; let regex: String; let replacement: String }
    private static let coverTemplates: [CoverTemplate] = [
        CoverTemplate(id: "T1", regex: "(.+)", replacement: "$1"),
        CoverTemplate(id: "T2", regex: #".*?(https?://[^"'\s]+?\.(?:webp|png|jpe?g|gif|avif))(?:\?[^\s"']*)?.*"#, replacement: "$1"),
        CoverTemplate(id: "T3", regex: #".*?(https?://[^"'\s]+?\.(?:webp|png|jpe?g|gif|avif)(?:\?[^\s"']*)?).*"#, replacement: "$1"),
        CoverTemplate(id: "T4", regex: #".*url\(["']?(.+?)["']?\).*"#, replacement: "$1"),
        CoverTemplate(id: "T5", regex: "(.+)", replacement: "https:$1"),
    ]

    /// applyCoverRegexStrict do web: sem casamento, devolve "" (o
    /// chamador cai pro valor limpo); {source:} = o valor cru.
    static func applyCoverRegexStrict(_ raw: String, regex: String, replacement: String) -> String {
        if regex.isEmpty { return raw }
        guard let re = HTMLKit.regex(regex) else { return "" }
        let range = NSRange(raw.startIndex..., in: raw)
        guard let m = re.firstMatch(in: raw, options: [], range: range) else { return "" }
        var rep = replacement.split(separator: "|").first.map(String.init) ?? "$1"
        if rep.isEmpty { rep = "$1" }
        var out = HTMLKit.expand(rep, match: m, in: raw)
        out = out.replacingOccurrences(of: "{source:}", with: raw)
        if replacement.hasPrefix("https:$1"), !out.hasPrefix("https:"), raw.hasPrefix("//") {
            out = "https:" + out
        }
        return out.replacingOccurrences(of: "\\/", with: "/")
    }

    private static func suggestCoverTemplate(_ raw: String, attr: String) -> CoverTemplate {
        if raw.hasPrefix("//") { return coverTemplates[4] }
        if raw.contains("url(") || attr == "style" { return coverTemplates[3] }
        if !isCleanCoverUrl(raw) {
            if raw.contains(",") { return coverTemplates[2] }
            return coverTemplates[1]
        }
        if hasImageExt(raw),
           raw.range(of: #"[?&].+"#, options: .regularExpression) != nil,
           raw.range(of: #"&amp;|token=|cache|utm_"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return coverTemplates[1]
        }
        return coverTemplates[0]
    }

    // MARK: Trio do item (web: suggestTitleRaw / detectCoverInItemRaw / suggestIdCodeRaw)

    private static func suggestTitleRaw(_ item: Element, ctx: TrioCtx) -> TitleRes? {
        let tries = ["h1 a", "h2 a", "h3 a", "h4 a", "h5 a", "h6 a",
                     ".entry-title a", ".title a", ".video-title a",
                     "h1", "h2", "h3", "h4", "h5", "h6",
                     ".entry-title", ".title", ".video-title",
                     "span.title", "span.video-title"]
        for sel in tries {
            guard let el = HTMLKit.first(item, sel) else { continue }
            let txt = el.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
            if !txt.isEmpty { return TitleRes(selector: sel, function: "text", param: nil, sample: txt) }
            let t = el.attrOrEmpty("title")
            if !t.isEmpty { return TitleRes(selector: sel, function: "attr", param: "title", sample: t) }
        }
        if let at = HTMLKit.first(item, "a[title]"), !at.attrOrEmpty("title").isEmpty {
            return TitleRes(selector: HTMLKit.uniqueRelSelector(root: item, target: at) ?? HTMLKit.buildSelector(at),
                            function: "attr", param: "title", sample: at.attrOrEmpty("title"))
        }
        if let it = HTMLKit.first(item, "img[title]"), !it.attrOrEmpty("title").isEmpty {
            return TitleRes(selector: HTMLKit.uniqueRelSelector(root: item, target: it) ?? HTMLKit.buildSelector(it),
                            function: "attr", param: "title", sample: it.attrOrEmpty("title"))
        }
        // [title] qualquer com texto próprio > 2
        for el in HTMLKit.descendants(of: item) where el !== item {
            let t = el.attrOrEmpty("title")
            if !t.isEmpty, el.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines).count > 2 {
                return TitleRes(selector: HTMLKit.uniqueRelSelector(root: item, target: el) ?? HTMLKit.buildSelector(el),
                                function: "attr", param: "title", sample: t)
            }
        }
        if let im = HTMLKit.first(item, "img[alt]"), !im.attrOrEmpty("alt").isEmpty {
            return TitleRes(selector: "img", function: "attr", param: "alt", sample: im.attrOrEmpty("alt"))
        }
        for el in HTMLKit.select(item, "p, span, div") {
            let txt = el.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.count > 3, HTMLKit.directChildren(of: el).isEmpty {
                return TitleRes(selector: HTMLKit.uniqueRelSelector(root: item, target: el) ?? HTMLKit.buildSelector(el),
                                function: "text", param: nil, sample: txt)
            }
        }
        for a in HTMLKit.select(item, "a") {
            let txt = a.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
            if txt.count > 3 {
                return TitleRes(selector: HTMLKit.uniqueRelSelector(root: item, target: a) ?? HTMLKit.buildSelector(a),
                                function: "text", param: nil, sample: txt)
            }
        }
        // item-âncora: o texto direto da própria âncora
        if item.tagName() == "a" {
            let own = item.textOrEmpty()
                .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
                .map(String.init).joined(separator: " ")
            if own.count > 3 { return TitleRes(selector: "this", function: "text", param: nil, sample: own) }
        }
        return nil
    }

    private static func detectCoverInItemRaw(_ item: Element) -> CoverRes? {
        struct Cand {
            var el: Element
            var attr: String
            var raw: String
            var value: String
            var score: Int
            var order: Int
        }
        var cands: [Cand] = []
        let bonus: [String: Int] = ["data-img-url": 40, "data-src": 30, "data-original": 28,
                                    "data-lazy-src": 26, "srcset": 24, "data-srcset": 24,
                                    "style": 22, "poster": 20, "src": 10]
        func push(_ el: Element, _ attr: String, _ raw: String, _ value: String) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { return }
            let cls = classifyCoverValue(value.isEmpty ? raw : value)
            if cls == "placeholder" || cls == "none" { return }
            var score = (cls == "strong") ? 100 : 50
            score += bonus[attr] ?? (attr.hasPrefix("data-") ? 15 : 0)
            cands.append(Cand(el: el, attr: attr, raw: raw, value: value.isEmpty ? raw : value,
                              score: score, order: cands.count))
        }
        let allEls = HTMLKit.descendants(of: item)   // inclui o próprio item
        // 5) data-img-url em qualquer elemento (ex.: span.entry-thumb sem img)
        for el in allEls where !el.attrOrEmpty("data-img-url").isEmpty {
            push(el, "data-img-url", el.attrOrEmpty("data-img-url"), el.attrOrEmpty("data-img-url"))
        }
        // 1–4, 6, 8) imgs: attrs conhecidos + srcset + qualquer outro data-*
        let known = ["data-src", "data-original", "data-lazy-src", "data-lazy", "data-image",
                     "data-bg", "data-background", "data-thumb", "data-cover", "data-poster", "src"]
        for img in HTMLKit.select(item, "img") {
            for a in known {
                let v = img.attrOrEmpty(a)
                if !v.isEmpty { push(img, a, v, v) }
            }
            for a in ["srcset", "data-srcset"] {
                let v = img.attrOrEmpty(a)
                if !v.isEmpty { push(img, a, v, parseSrcsetLargest(v)) }
            }
            for at in HTMLKit.allAttributes(img) where at.name.hasPrefix("data-") && !known.contains(at.name) {
                if !at.value.isEmpty { push(img, at.name, at.value, at.value) }
            }
        }
        // 6 generalizado) qualquer elemento, qualquer data-* com cara de imagem
        for el in allEls {
            for at in HTMLKit.allAttributes(el) where at.name.hasPrefix("data-") && at.name != "data-img-url" {
                if at.value.isEmpty { continue }
                if classifyCoverValue(at.value) == "none" { continue }
                push(el, at.name, at.value, at.value)
            }
        }
        // 7) background-image em style
        for el in allEls {
            let st = el.attrOrEmpty("style")
            if st.range(of: "url\\(", options: .regularExpression) != nil,
               let u = extractBgUrl(st) {
                push(el, "style", st, u)
            }
        }
        // 8) picture > source srcset
        for srcEl in HTMLKit.select(item, "picture source") {
            let v = !srcEl.attrOrEmpty("srcset").isEmpty ? srcEl.attrOrEmpty("srcset") : srcEl.attrOrEmpty("data-srcset")
            if !v.isEmpty { push(srcEl, "srcset", v, parseSrcsetLargest(v)) }
        }
        // 9) video[poster]
        for vid in HTMLKit.select(item, "video") where !vid.attrOrEmpty("poster").isEmpty {
            push(vid, "poster", vid.attrOrEmpty("poster"), vid.attrOrEmpty("poster"))
        }
        if cands.isEmpty {
            // fallback compat: detectCover clássico no primeiro img
            if let img = HTMLKit.first(item, "img"), let classic = classicCover(of: img) {
                return CoverRes(selector: "img", attr: classic.attr, param: classic.attr,
                                rawValue: classic.value, value: classic.value,
                                regex: "(.+)", replacement: "$1",
                                lazy: classic.attr != "src", bestEl: img)
            }
            return nil
        }
        cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
        let best = cands[0]
        // param múltiplo (v3.5): a imagem tem mais de um atributo válido
        var param = best.attr
        if best.el.tagName() == "img" {
            let pri = ["data-src", "data-original", "data-lazy-src", "data-lazy", "data-image",
                       "data-bg", "data-background", "data-thumb", "data-cover", "data-poster", "src"]
            var present: [String] = []
            for c in cands where c.el === best.el && pri.contains(c.attr) && !present.contains(c.attr) {
                present.append(c.attr)
            }
            present.sort { pri.firstIndex(of: $0)! < pri.firstIndex(of: $1)! }
            if present.count >= 2 {
                param = present.joined(separator: ", ")
            } else {
                let hasSrc = best.el.attrOrEmpty("src")
                if ["data-src", "data-original", "data-lazy-src"].contains(best.attr), !hasSrc.isEmpty {
                    if best.attr == "data-lazy-src" {
                        if !isPlaceholderSrc(hasSrc) { param = best.attr + ", src" }
                    } else {
                        param = best.attr + ", src"
                    }
                }
            }
        }
        var tpl = suggestCoverTemplate(best.raw, attr: best.attr)
        var finalVal = applyCoverRegexStrict(best.raw, regex: tpl.regex, replacement: tpl.replacement)
        if finalVal.isEmpty { finalVal = best.value }
        if !best.raw.hasPrefix("//"), tpl.id == "T5" {
            tpl = coverTemplates[0]
            let retry = applyCoverRegexStrict(best.raw, regex: tpl.regex, replacement: tpl.replacement)
            finalVal = retry.isEmpty ? best.value : retry
        }
        let selector = (best.el === item) ? "this"
            : (HTMLKit.uniqueRelSelector(root: item, target: best.el) ?? HTMLKit.buildSelector(best.el))
        return CoverRes(selector: selector, attr: best.attr, param: param,
                        rawValue: best.raw, value: finalVal,
                        regex: tpl.regex, replacement: tpl.replacement,
                        lazy: best.attr != "src" && best.el.tagName() == "img",
                        bestEl: best.el)
    }

    /// detectCover CLÁSSICO do web (um <img> só): a ordem de preferência
    /// dos attrs com valor que parece imagem e não é placeholder.
    private static func classicCover(of img: Element) -> (attr: String, value: String)? {
        let order = ["data-src", "data-original", "data-lazy-src", "srcset", "data-srcset", "src"]
        var found: [String: String] = [:]
        for a in ["data-src", "data-original", "data-lazy-src", "data-srcset", "src"] {
            let v = img.attrOrEmpty(a)
            if !v.isEmpty { found[a] = v.trimmingCharacters(in: .whitespaces) }
        }
        if !img.attrOrEmpty("srcset").isEmpty {
            found["srcset"] = img.attrOrEmpty("srcset").trimmingCharacters(in: .whitespaces)
        }
        for a in order {
            guard let v = found[a] else { continue }
            let val = (a == "srcset" || a == "data-srcset")
                ? (v.split(separator: ",").first.map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? "" } ?? "")
                : v
            if looksLikeImageUrl(val), !isPlaceholderSrc(val) { return (a, val) }
        }
        for a in order { if let v = found[a] { return (a, v) } }
        return nil
    }

    // MARK: idCode do item (web: preferredAnchor / idCodeTransform / suggestIdCodeRaw)

    static func resolveForCompare(_ href: String, origin: String) -> String {
        HTMLKit.absolutize(href.trimmingCharacters(in: .whitespaces), origin: origin)
    }

    private static func preferredAnchor(in item: Element, ctx: TrioCtx) -> Element? {
        guard !ctx.exampleResolved.isEmpty else { return nil }
        var anchors: [Element] = []
        if item.tagName() == "a", !item.attrOrEmpty("href").isEmpty { anchors.append(item) }
        anchors += HTMLKit.select(item, "a[href]")
        var best: Element? = nil
        var bestScore = -1
        for a in anchors {
            let href = a.attrOrEmpty("href")
            if href.isEmpty { continue }
            if resolveForCompare(href, origin: ctx.origin) == ctx.exampleResolved {
                best = a; bestScore = 1000; continue
            }
            if bestScore >= 1000 { continue }
            let segs = TrioCtx.pathSegments(of: resolveForCompare(href, origin: ctx.origin))
            if segs.count != ctx.exampleSegs.count || segs.isEmpty { continue }
            var eq = 0
            for i in segs.indices where segs[i] == ctx.exampleSegs[i] { eq += 1 }
            // o slug do detalhe muda no último segmento; os demais têm que bater
            if eq >= segs.count - 1, eq > bestScore { bestScore = eq; best = a }
        }
        return bestScore >= 0 ? best : nil
    }

    /// O anchor CERTO de um item (a mesma escada do suggestIdCodeRaw) —
    /// nunca resolvido via querySelector de um seletor derivado.
    private static func idAnchor(in item: Element, ctx: TrioCtx) -> Element? {
        if let a = preferredAnchor(in: item, ctx: ctx) { return a }
        if let withImg = HTMLKit.first(item, "a img") {
            var cur: Element? = withImg
            while let c = cur {
                if c.tagName() == "a" { return c }
                cur = c.parent()
            }
        }
        if let a = HTMLKit.first(item, "h1 a, h2 a, h3 a, h4 a") { return a }
        if let a = HTMLKit.first(item, "a[href]") { return a }
        if item.tagName() == "a" { return item }
        return nil
    }

    static func idCodeTransform(_ hrefRaw: String, origin: String) -> (regex: String, replacement: String) {
        let href = hrefRaw.trimmingCharacters(in: .whitespaces)
        let domain = origin.hasSuffix("/") ? String(origin.dropLast()) : origin
        if href.hasPrefix("//") { return ("(.+)", "https:$1") }
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return ("(.+)", "$1") }
        if href.hasPrefix("/") { return ("(.+)", domain + "$1") }
        if href.isEmpty || href.hasPrefix("#") || href.lowercased().hasPrefix("javascript:") {
            return ("(.+)", "$1")
        }
        return ("(.+)", (domain.isEmpty ? "/" : domain + "/") + "$1")
    }

    static func validateFinalUrl(_ finalUrl: String, origin: String) -> Bool {
        if finalUrl.isEmpty { return false }
        if finalUrl.hasPrefix("#") { return false }
        if finalUrl.lowercased().hasPrefix("javascript:") { return false }
        guard finalUrl.hasPrefix("http://") || finalUrl.hasPrefix("https://") else { return false }
        if !origin.isEmpty {
            let fh = HTMLKit.host(of: finalUrl)
            let oh = HTMLKit.host(of: origin)
            if !fh.isEmpty && !oh.isEmpty && fh != oh { return false }
        }
        return true
    }

    private static func suggestIdCodeRaw(_ item: Element, ctx: TrioCtx) -> IdRes? {
        guard let a = idAnchor(in: item, ctx: ctx) else { return nil }
        let href = a.attrOrEmpty("href")
        let t = idCodeTransform(href, origin: ctx.origin)
        let selector = HTMLKit.uniqueRelSelector(root: item, target: a) ?? HTMLKit.buildSelector(a)
        let finalUrl = t.replacement.replacingOccurrences(of: "$1", with: href)
        return IdRes(selector: selector, regex: t.regex, replacement: t.replacement,
                     sample: href, finalUrl: finalUrl)
    }

    /// idExtract315: aplica regex+replacement sobre o href (sem casamento = "").
    static func idExtract(_ href: String, regex: String, replacement: String) -> String {
        if regex.isEmpty { return href }
        return HTMLKit.firstCapture(regex, in: href, replacement: replacement) ?? ""
    }

    // MARK: Geração de candidatos (web: analyzeList)

    /// Assinatura estrutural do bloco (web blockSignature): tag |
    /// classes | tags dos descendentes até profundidade 2 (máx. 14).
    private static func blockSignature(_ el: Element) -> String {
        var desc: [String] = []
        func walk(_ node: Element, _ depth: Int) {
            if depth > 2 { return }
            for c in HTMLKit.directChildren(of: node) {
                desc.append(c.tagName())
                walk(c, depth + 1)
            }
        }
        walk(el, 1)
        let cls = HTMLKit.classesInOrder(el).joined(separator: ".")
        return el.tagName() + "|" + cls + "|" + desc.prefix(14).joined(separator: ",")
    }

    private static func isSemanticGroup(_ g: BlockGroup, ctx: TrioCtx) -> Bool {
        guard let el = g.els.first else { return false }
        let cls = el.attrOrEmpty("class")
        if el.tagName() == "article" { return true }
        if cls.range(of: "post", options: .regularExpression) != nil { return true }
        return !HTMLKit.select(el, ".entry-title, .post-title, h1 a, h2 a").isEmpty
    }

    /// Passo de família v3.13: os órfãos da assinatura exata (grupos com
    /// < 3 itens) são reagrupados por tag + classes COMUNS; o seletor é
    /// derivado do núcleo e VALIDADO no documento (casamento exato, ou
    /// superconjunto cujos extras também parecem itens).
    private static func familyGroups(doc: Document, groups: [String: [Element]],
                                     ctx: TrioCtx) -> [BlockGroup] {
        var byTag: [String: [Element]] = [:]
        for (_, els) in groups where els.count < 3 {
            for el in els {
                let tag = el.tagName()
                if byTag[tag]?.contains(where: { $0 === el }) != true {
                    byTag[tag, default: []].append(el)
                }
            }
        }
        func classRank(_ c: String, freq: Int) -> Double {
            var s = 0.0
            if c.range(of: "post|entry|item|card|article|product|video|story|news|loop|thumb|content",
                       options: [.regularExpression, .caseInsensitive]) == nil { s += 1000 }
            if c.contains(where: { $0.isNumber }) { s += 500 }
            s -= Double(min(freq, 50))
            s += Double(min(c.count, 40)) * 0.1
            return s
        }
        var budget = 60
        var out: [BlockGroup] = []
        for (tag, els) in byTag where els.count >= 3 {
            let n = els.count
            var freq: [String: Int] = [:]
            for el in els {
                for c in Set(HTMLKit.classesInOrder(el)) { freq[c, default: 0] += 1 }
            }
            let thresholds = [n, max(2, Int(ceil(Double(n) * 0.75))), max(2, Int(ceil(Double(n) * 0.6)))]
            var done = false
            for minF in thresholds where !done {
                let core = freq.filter { $0.value >= minF }.map { $0.key }
                if core.isEmpty { continue }
                var members = els.filter { el in
                    let cs = HTMLKit.classesInOrder(el)
                    return core.allSatisfy { cs.contains($0) }
                }
                if members.count < 3 { continue }
                let ranked = core.sorted { classRank($0, freq: freq[$0] ?? 0) < classRank($1, freq: freq[$1] ?? 0) }
                // derivar o seletor: prefixos do núcleo, k = 1..4
                var derived: String? = nil
                var bestSup: (sel: String, matched: [Element])? = nil
                let maxK = min(4, ranked.count)
                for k in 1...maxK {
                    if budget <= 0 { break }
                    budget -= 1
                    let candSel = tag + "." + ranked.prefix(k).joined(separator: ".")
                    let matched = HTMLKit.select(doc, candSel)
                    if matched.isEmpty { continue }
                    guard members.allSatisfy({ m in matched.contains(where: { $0 === m }) }) else { continue }
                    if matched.count == members.count { derived = candSel; break }
                    if bestSup == nil || matched.count < bestSup!.matched.count {
                        bestSup = (candSel, matched)
                    }
                }
                if derived == nil, let sup = bestSup {
                    let memberIDs = Set(members.map { ObjectIdentifier($0) })
                    let extras = sup.matched.filter { !memberIDs.contains(ObjectIdentifier($0)) }
                    var good = 0
                    for e in extras.prefix(12) {
                        if ctx.idCode(e) != nil && (ctx.cover(e) != nil || ctx.title(e) != nil) { good += 1 }
                    }
                    if !extras.isEmpty, Double(good) / Double(min(extras.count, 12)) >= 0.8 {
                        members = sup.matched
                        derived = sup.sel
                    }
                }
                guard let sel = derived else { continue }
                let dup = groups.values.contains { $0.count == members.count && $0.first === members.first }
                if dup { done = true; continue }
                out.append(BlockGroup(selector: sel, els: members))
                done = true
            }
        }
        return out
    }

    /// Seletor robusto v1.8 aplicado ao grupo + validação de contagem.
    private static func robustify(doc: Document, group g: BlockGroup) {
        guard let first = g.els.first else { return }
        let full = g.selector
        let robust = HTMLKit.buildRobustSelector(first)
        let dropped = HTMLKit.classesInOrder(first).filter { HTMLKit.isVolatileClass($0) }
        if dropped.isEmpty || robust == full { return }
        let matched = HTMLKit.select(doc, robust)
        if matched.isEmpty { return }
        let n = g.els.count
        if abs(matched.count - n) <= max(1, Int((Double(n) * 0.05).rounded())) {
            g.selector = robust
            return
        }
        if matched.count > n {
            let fullIDs = Set(g.els.map { ObjectIdentifier($0) })
            let extras = matched.filter { !fullIDs.contains(ObjectIdentifier($0)) }
            // DESVIO: o web valida o superconjunto com o trio do item;
            // aqui a checagem é estrutural (link + img dentro), porque o
            // trio memoizado por elemento tornaria esta etapa a mais
            // cara da análise em páginas grandes.
            let good = extras.prefix(12).filter {
                !HTMLKit.select($0, "a[href]").isEmpty
                    && (!HTMLKit.select($0, "img").isEmpty || $0.tagName() == "a")
            }.count
            if !extras.isEmpty, Double(good) / Double(min(extras.count, 12)) >= 0.8 {
                g.selector = robust
                g.els = matched
            }
        }
    }

    /// Detector de blocos estruturais do web: filhos em sequência com a
    /// mesma assinatura estrutural sob o mesmo pai (cards sem classe
    /// útil). Orçamentos duros iguais aos do web (8000 pais, 240 trios).
    private static func detectBlocks(doc: Document, ctx: TrioCtx) -> [BlockGroup] {
        var out: [BlockGroup] = []
        var evalBudget = 240
        let parents = HTMLKit.descendants(of: doc)
        var parentCount = 0
        for parent in parents {
            if parentCount >= 8000 { break }
            parentCount += 1
            let kids = HTMLKit.directChildren(of: parent)
            if kids.count < 4 { continue }
            var gEls: [String: [Element]] = [:]
            var gIdx: [String: [Int]] = [:]
            var order: [String] = []
            for (idx, k) in kids.enumerated() {
                let sig = blockSignature(k)
                if gEls[sig] == nil { order.append(sig) }
                gEls[sig, default: []].append(k)
                gIdx[sig, default: []].append(idx)
            }
            for sig in order {
                guard let els = gEls[sig], els.count >= 4 else { continue }
                let idxs = gIdx[sig] ?? []
                let span = (idxs.last ?? 0) - (idxs.first ?? 0) + 1
                if span - els.count > 2 { continue }
                let g = (els: els, idxs: idxs)
                var withA = 0, withTC = 0, withCover = 0, withTitle = 0, withLink = 0
                var aborted = false
                for el in g.els {
                    if evalBudget <= 0 { aborted = true; break }
                    evalBudget -= 1
                    let hasA = el.tagName() == "a" || !HTMLKit.select(el, "a[href]").isEmpty
                    let tt = ctx.title(el)
                    let cc = ctx.cover(el)
                    let idc = ctx.idCode(el)
                    if hasA { withA += 1 }
                    if tt != nil || cc != nil { withTC += 1 }
                    if cc != nil { withCover += 1 }
                    if tt != nil { withTitle += 1 }
                    if idc != nil { withLink += 1 }
                }
                if aborted { continue }
                let n = Double(g.els.count)
                if Double(withA) / n < 0.7 { continue }
                if Double(withTC) / n < 0.7 { continue }
                if Double(withCover) / n < 0.3 { continue }
                guard let first = g.els.first else { continue }
                let childSel = HTMLKit.selForEl(first)
                let parentSel = HTMLKit.selForEl(parent)
                var selector = childSel
                if HTMLKit.select(doc, childSel).count != g.els.count
                    || HTMLKit.classesInOrder(first).isEmpty {
                    selector = parentSel + " > " + childSel
                }
                if out.contains(where: { $0.selector == selector && $0.els.count == g.els.count && $0.els.first === first }) { continue }
                let bg = BlockGroup(selector: selector, els: g.els)
                bg.isBlock = true
                bg.statsPct = (Int((Double(withCover) / n * 100).rounded()),
                               Int((Double(withTitle) / n * 100).rounded()),
                               Int((Double(withLink) / n * 100).rounded()))
                out.append(bg)
            }
        }
        out.sort { $0.els.count > $1.els.count }
        return Array(out.prefix(6))
    }

    /// Padrão item-âncora v2.0.4: o card É o link — âncoras-irmãs sob o
    /// mesmo pai, agrupadas pelo seletor delas (não pela estrutura
    /// interna, que os selos/metadados quebrariam).
    private static func detectAnchorItems(doc: Document, ctx: TrioCtx) -> [BlockGroup] {
        var out: [BlockGroup] = []
        var evalBudget = 600
        let parents = HTMLKit.descendants(of: doc)
        var parentCount = 0
        for parent in parents {
            if parentCount >= 8000 { break }
            parentCount += 1
            let kids = HTMLKit.directChildren(of: parent).filter { $0.tagName() == "a" }
            if kids.count < 3 { continue }
            var groups: [String: [Element]] = [:]
            var order: [String] = []
            for k in kids {
                let key = HTMLKit.selForEl(k)
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(k)
            }
            for key in order {
                guard let els = groups[key], els.count >= 3 else { continue }
                let sample = Array(els.prefix(60))
                var withHref = 0, withCover = 0, withTitle = 0, withLink = 0, withMedia = 0
                var exhausted = false
                for el in sample {
                    if evalBudget <= 0 { exhausted = true; break }
                    evalBudget -= 1
                    let href = el.attrOrEmpty("href").trimmingCharacters(in: .whitespaces)
                    if !href.isEmpty, !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:") { withHref += 1 }
                    let cc = ctx.cover(el)
                    let tt = ctx.title(el)
                    let idc = ctx.idCode(el)
                    let hasMediaTitle = cc != nil
                        || !HTMLKit.select(el, "img, picture, video, h1, h2, h3, h4, h5, h6").isEmpty
                    if cc != nil { withCover += 1 }
                    if tt != nil { withTitle += 1 }
                    if idc != nil { withLink += 1 }
                    if hasMediaTitle { withMedia += 1 }
                }
                if exhausted { continue }
                let n = Double(sample.count)
                if n == 0 { continue }
                if Double(withHref) / n < 0.7 { continue }
                if Double(withMedia) / n < 0.7 { continue }
                if Double(withCover) / n < 0.3, Double(withTitle) / n < 0.7 { continue }
                guard let first = els.first else { continue }
                var selector = key
                if HTMLKit.select(doc, key).count != els.count
                    || HTMLKit.classesInOrder(first).isEmpty {
                    selector = HTMLKit.selForEl(parent) + " > " + key
                }
                if out.contains(where: { $0.selector == selector && $0.els.count == els.count && $0.els.first === first }) { continue }
                let bg = BlockGroup(selector: selector, els: els)
                bg.isBlock = true
                bg.isAnchorItem = true
                bg.statsPct = (Int((Double(withCover) / n * 100).rounded()),
                               Int((Double(withTitle) / n * 100).rounded()),
                               Int((Double(withLink) / n * 100).rounded()))
                out.append(bg)
            }
        }
        out.sort { $0.els.count > $1.els.count }
        return Array(out.prefix(6))
    }

    private static func sameItemCoverage(_ a: BlockGroup, _ b: BlockGroup) -> Bool {
        if a.els.isEmpty || b.els.isEmpty || a.els.count != b.els.count { return false }
        if a.els.first === b.els.first { return true }
        func strictInside(_ inner: Element, of outer: Element) -> Bool {
            var cur = inner.parent()
            while let c = cur {
                if c === outer { return true }
                cur = c.parent()
            }
            return false
        }
        if b.els.allSatisfy({ be in a.els.contains { ae in ae !== be && strictInside(be, of: ae) } }) { return true }
        if a.els.allSatisfy({ ae in b.els.contains { be in be !== ae && strictInside(ae, of: be) } }) { return true }
        return false
    }

    private static func candidateCompleteness(_ g: BlockGroup, ctx: TrioCtx) -> Double {
        let sample = Array(g.els.prefix(5))
        if sample.isEmpty { return 0 }
        var s = 0.0
        for el in sample {
            if ctx.cover(el) != nil { s += 1 }
            if ctx.title(el) != nil { s += 1 }
            if let idc = ctx.idCode(el), validateFinalUrl(idc.finalUrl, origin: ctx.origin) { s += 1 }
        }
        return s / Double(sample.count)
    }

    // MARK: Pontuação e guardas (web: scoreListAdj37 / applyListGuards311 / gatePick37)

    static func elLateral(_ el: Element) -> Bool {
        var cur: Element? = el
        var hops = 0
        while let c = cur, hops < 14 {
            if c.tagName() == "aside" { return true }
            let cid = (HTMLKit.classesInOrder(c).joined(separator: " ") + " " + c.attrOrEmpty("id"))
            if cid.range(of: "widget|sidebar|textwidget", options: [.regularExpression, .caseInsensitive]) != nil { return true }
            cur = c.parent()
            hops += 1
        }
        return false
    }

    private static func scoreAdjust(_ g: BlockGroup, base: Int, ctx: TrioCtx) -> Int {
        var score = base
        // (A) lealdade ao domínio: % de hrefs no mesmo host
        let siteHost = HTMLKit.host(of: ctx.origin)
        var domTotal = 0, domSame = 0
        for el in g.els.prefix(10) {
            guard let idc = ctx.idCode(el) else { continue }
            let href = idc.sample
            if href.isEmpty || href.hasPrefix("#") || href.lowercased().hasPrefix("javascript:") { continue }
            let hh = HTMLKit.host(of: idc.finalUrl.isEmpty ? href : idc.finalUrl)
            if hh.isEmpty { continue }
            domTotal += 1
            if !siteHost.isEmpty && hh == siteHost { domSame += 1 }
        }
        let domPct = domTotal > 0 ? Int((Double(domSame) / Double(domTotal) * 100).rounded()) : 0
        g.blogroll = domTotal >= 3 && domPct < 50
        // (A) taxa do clique: a URL final é válida em quantos itens
        var pass = 0, total = 0
        for el in g.els.prefix(5) {
            total += 1
            if let idc = ctx.idCode(el), validateFinalUrl(idc.finalUrl, origin: ctx.origin) { pass += 1 }
        }
        g.clickPass = pass
        g.clickTotal = total
        let clickRate = total > 0 ? Double(pass) / Double(total) : 0
        g.clickPasses = total > 0 && clickRate >= 0.8
        score += Int((clickRate * 40).rounded())
        // (B) semântico × lateral
        var semN = 0, semTot = 0, latN = 0, latTot = 0
        for el in g.els.prefix(10) {
            semTot += 1
            let cls = el.attrOrEmpty("class")
            var sem = el.tagName() == "article"
                || cls.range(of: #"(^|\s)post(\s|$)|(^|[\s.])post-"#, options: .regularExpression) != nil
            if !sem {
                sem = !HTMLKit.select(el, ".entry-title a, .post-title a, h1 a, h2 a").isEmpty
            }
            if sem { semN += 1 }
            latTot += 1
            if elLateral(el) { latN += 1 }
        }
        let isSemantic = semTot > 0 && Double(semN) / Double(semTot) >= 0.5
        g.isLateral = latTot > 0 && Double(latN) / Double(latTot) >= 0.5
        if isSemantic { score += 60 }
        if g.isLateral { score -= 80 }
        if g.blogroll { score -= 60 }
        return score
    }

    static func hrefFamily(_ hrefRaw: String, origin: String) -> String {
        let h = hrefRaw.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return "" }
        let noFrag = h.split(separator: "#", maxSplits: 1).first.map(String.init) ?? h
        if let qi = noFrag.firstIndex(of: "?") {
            let query = String(noFrag[noFrag.index(after: qi)...])
            let key = query.split(separator: "&").first?
                .split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if !key.isEmpty { return "query:" + key }
        }
        let resolved = resolveForCompare(noFrag, origin: origin)
        let path = URL(string: resolved)?.path ?? noFrag
        let segs = path.split(separator: "/").map(String.init)
        if segs.isEmpty { return "path:/" }
        let shape = segs.map { s -> String in
            if s.allSatisfy({ $0.isNumber }) { return "num" }
            if s.contains(where: { $0.isNumber }), !s.contains("-"), s.count <= 14 { return "id" }
            if s.contains("-") || s.count > 14 { return "slug" }
            return "seg"
        }
        return "path:" + shape.joined(separator: "/")
    }

    private static func applyListGuards(_ cands: [BlockGroup], ctx: TrioCtx) {
        // (1) ANINHAMENTO −120: os itens vivem dentro dos itens de outro
        func strictAncestor(_ el: Element, in set: Set<ObjectIdentifier>) -> Bool {
            var cur = el.parent()
            var hops = 0
            while let c = cur, hops < 40 {
                if set.contains(ObjectIdentifier(c)) { return true }
                cur = c.parent()
                hops += 1
            }
            return false
        }
        for g in cands where !g.els.isEmpty {
            var pts = 0
            var bestF: BlockGroup? = nil
            var bestFrac = 0.0
            for f in cands where f !== g && !f.els.isEmpty {
                let fset = Set(f.els.map { ObjectIdentifier($0) })
                let inside = g.els.filter { strictAncestor($0, in: fset) }.count
                let frac = Double(inside) / Double(g.els.count)
                if frac > bestFrac { bestFrac = frac; bestF = f }
            }
            if let f = bestF, bestFrac >= 0.8 {
                let gset = Set(g.els.map { ObjectIdentifier($0) })
                let back = f.els.filter { strictAncestor($0, in: gset) }.count
                let backFrac = f.els.isEmpty ? 0 : Double(back) / Double(f.els.count)
                if backFrac < 0.8 {
                    pts -= 120
                    g.guardNotes.append("itens aninhados dentro do bloco \(f.selector) — penalizado no ranking")
                }
            }
            let sample = Array(g.els.prefix(10))
            // (2) TÍTULO VAZIO −90
            var empty = 0
            for el in sample {
                let t = ctx.title(el)
                if t == nil || t!.sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { empty += 1 }
            }
            if sample.count >= 3, empty * 2 > sample.count {
                pts -= 90
                g.guardNotes.append("título vazio em \(empty) de \(sample.count) itens — penalizado no ranking")
            }
            // (3) HREF INCONSISTENTE −60
            var fams: [String: Int] = [:]
            var hrefN = 0, topN = 0
            for el in sample {
                guard let idc = ctx.idCode(el) else { continue }
                let fam = hrefFamily(idc.sample.isEmpty ? idc.finalUrl : idc.sample, origin: ctx.origin)
                if fam.isEmpty { continue }
                hrefN += 1
                fams[fam, default: 0] += 1
                topN = max(topN, fams[fam] ?? 0)
            }
            if hrefN >= 4, fams.count >= 2, Double(topN) / Double(hrefN) < 0.75 {
                pts -= 60
                g.guardNotes.append("hrefs de famílias misturadas no mesmo bloco — penalizado no ranking")
            }
            // (4) CAPA REPETIDA −50
            var covs: [String: Int] = [:]
            var covN = 0, topCovN = 0
            for el in sample {
                guard let c = ctx.cover(el) else { continue }
                let v = c.value.trimmingCharacters(in: .whitespaces)
                if v.isEmpty || isPlaceholderSrc(v) { continue }
                covN += 1
                covs[v, default: 0] += 1
                topCovN = max(topCovN, covs[v] ?? 0)
            }
            if covN >= 3, topCovN * 2 >= covN {
                pts -= 50
                g.guardNotes.append("a mesma capa se repete em \(topCovN) de \(covN) itens — penalizado no ranking")
            }
            g.score += pts
        }
    }

    /// O portão v3.7: melhor bloco que passa no clique e não é blogroll;
    /// senão o melhor não-blogroll (fallback declarado); senão o melhor.
    private static func gatePick(_ cands: [BlockGroup]) -> (idx: Int, fallback: Bool, reason: String) {
        for (i, c) in cands.enumerated() where !c.blogroll && c.clickPasses {
            return (i, false, "melhor bloco que passa no clique e não é blogroll")
        }
        for (i, c) in cands.enumerated() where !c.blogroll {
            return (i, true, "nenhum bloco passou no clique — pré-selecionado o melhor bloco não-blogroll mesmo assim")
        }
        return (0, true, "todos os blocos são blogroll/parceiros — pré-selecionado o melhor mesmo assim")
    }

    // MARK: Aplicação do bloco (web: stabilizeFieldSelectors314 + minimizeIdCodeSelector315 + face lazy)

    /// Elemento pretendido de um campo dentro de um item (v3.14).
    /// DESVIO: pro cover, o web reencontra o elemento casando
    /// seletor+attr entre os candidatos; aqui uso o bestEl guardado pelo
    /// próprio detector (o elemento do candidato vencedor) — o mesmo
    /// elemento, sem a segunda busca.
    private static func fieldElement(kind: String, tupleSelector: String, item: Element, ctx: TrioCtx) -> Element? {
        if kind == "cover" {
            return ctx.cover(item)?.bestEl
        }
        if tupleSelector == "this" { return item }
        return HTMLKit.first(item, tupleSelector)
    }

    private static func stabilizeFields(_ g: BlockGroup, ctx: TrioCtx, notes: inout [String]) {
        let items = Array(g.els.prefix(8))
        if items.count < 2 { return }
        // idCode NÃO passa por aqui — a lei do seletor mínimo é dona dele.
        if var cov = g.cover, cov.selector != "this" {
            stabilizeOne(selector: cov.selector, kind: "cover", items: items, ctx: ctx) { newSel in
                cov.selector = newSel
                g.cover = cov
            }
        }
        if var tit = g.title, tit.selector != "this" {
            stabilizeOne(selector: tit.selector, kind: "title", items: items, ctx: ctx) { newSel in
                tit.selector = newSel
                g.title = tit
            }
        }
        _ = notes
    }

    private static func stabilizeOne(selector orig: String, kind: String, items: [Element],
                                     ctx: TrioCtx, apply: (String) -> Void) {
        var els: [Element] = []
        for it in items {
            guard let e = fieldElement(kind: kind, tupleSelector: orig, item: it, ctx: ctx) else { return }
            els.append(e)
        }
        func validates(_ sel: String) -> Bool {
            for i in items.indices {
                if HTMLKit.first(items[i], sel) !== els[i] { return false }
            }
            return true
        }
        if validates(orig) { return }
        guard let firstEl = els.first else { return }
        let common = HTMLKit.stableClasses(firstEl).filter { c in
            els.allSatisfy { HTMLKit.classesInOrder($0).contains(c) }
        }
        // variantes: tag+classes comuns (todas → menos → tag pura),
        // depois as mesmas com o prefixo ancestral do seletor original
        let tag = firstEl.tagName()
        var simples: [String] = []
        if !common.isEmpty {
            for k in stride(from: common.count, through: 1, by: -1) {
                simples.append(tag + "." + common.prefix(k).joined(separator: "."))
            }
        }
        simples.append(tag)
        var variants: [String] = []
        for s in simples where !variants.contains(s) { variants.append(s) }
        let parts = orig.split(whereSeparator: { $0 == " " || $0 == ">" }).map(String.init).filter { !$0.isEmpty }
        if parts.count > 1 {
            let prefix = parts.dropLast().joined(separator: " ")
            for s in simples {
                let v = prefix + " " + s
                if !variants.contains(v) { variants.append(v) }
            }
        }
        for v in variants where v != orig {
            if validates(v) { apply(v); return }
        }
    }

    /// Lei do seletor mínimo do idCode (v3.15): da forma mais simples
    /// pra mais específica, validando pela EXTRAÇÃO — a URL certa em
    /// TODOS os itens da amostra.
    private static func minimizeIdCode(_ g: BlockGroup, ctx: TrioCtx, notes: inout [String]) {
        guard var tuple = g.idc else { return }
        let items = Array(g.els.prefix(8))
        if items.isEmpty { return }
        if tuple.selector == "this" { return }
        var anchors: [Element] = []
        for it in items {
            guard let an = idAnchor(in: it, ctx: ctx) else { return }   // sem o anchor certo em algum item: não mexe
            anchors.append(an)
        }
        let expected = anchors.map { idExtract($0.attrOrEmpty("href"), regex: tuple.regex, replacement: tuple.replacement) }
        if expected.contains(where: { $0.isEmpty }) { return }
        func validates(_ sel: String) -> Bool {
            for i in items.indices {
                guard let m = HTMLKit.first(items[i], sel), m.tagName() == "a" else { return false }
                if idExtract(m.attrOrEmpty("href"), regex: tuple.regex, replacement: tuple.replacement) != expected[i] { return false }
            }
            return true
        }
        var cands: [String] = []
        func pushC(_ s: String) {
            if !s.isEmpty, !cands.contains(s) { cands.append(s) }
        }
        pushC("a")
        let commonCls = HTMLKit.classesInOrder(anchors[0]).filter { c in
            anchors.allSatisfy { HTMLKit.classesInOrder($0).contains(c) }
        }
        for c in commonCls { pushC("a." + c) }
        if commonCls.count > 1 {
            for i in commonCls.indices {
                for j in (i + 1)..<commonCls.count {
                    pushC("a." + commonCls[i] + "." + commonCls[j])
                }
            }
        }
        var chain: [Element] = []
        var cur = anchors[0].parent()
        while let c = cur, c !== items[0], chain.count < 4 {
            chain.append(c)
            cur = c.parent()
        }
        for anc in chain {
            let atag = anc.tagName()
            pushC(atag + " a")
            let acls = HTMLKit.stableClasses(anc)
            for c in acls { pushC(atag + "." + c + " a") }
            if acls.count > 1 { pushC(atag + "." + acls.joined(separator: ".") + " a") }
            for c in commonCls { pushC(atag + " a." + c) }
        }
        let parts = tuple.selector.split(whereSeparator: { $0 == " " || $0 == ">" }).map(String.init).filter { !$0.isEmpty }
        if parts.count > 1 {
            let prefix = parts.dropLast().joined(separator: " ")
            pushC(prefix + " a")
            for c in commonCls { pushC(prefix + " a." + c) }
        }
        func simplicity(_ s: String) -> (Int, Int, Int) {
            let segs = s.split(whereSeparator: { $0 == " " || $0 == ">" }).filter { !$0.isEmpty }.count
            let cls = s.filter { $0 == "." }.count
            return (segs, cls, s.count)
        }
        cands.sort {
            let x = simplicity($0), y = simplicity($1)
            if x.0 != y.0 { return x.0 < y.0 }
            if x.1 != y.1 { return x.1 < y.1 }
            return x.2 < y.2
        }
        var chosen: String? = nil
        for c in cands where validates(c) { chosen = c; break }
        guard let chosen else {
            notes.append("idCode: nenhuma forma mais simples validou em todos os itens — mantido o seletor original (\(tuple.selector))")
            return
        }
        if chosen != tuple.selector {
            tuple.selector = chosen
            g.idc = tuple
        }
        if chosen.contains(" ") {
            notes.append("idCode: forma composta inevitável (\(chosen)) — validada pela extração em todos os itens")
        }
    }

    /// Face lazy da lista (v3.8): a maquinaria lazy no bloco escolhido
    /// manda o param da capa — o app lê o HTML cru, onde o src é o
    /// placeholder e a URL real mora no atributo lazy.
    private static func lazyFace(of items: [Element]) -> (present: Bool, dataLazySrc: Int, dataSrc: Int, signals: [String]) {
        var imgs: [Element] = []
        for el in items {
            if el.tagName() == "img" { imgs.append(el) }
            imgs += HTMLKit.select(el, "img")
        }
        var dataLazySrc = 0, dataSrc = 0, llStatus = false, lazyClass = false
        var srcCount: [String: Int] = [:]
        for img in imgs {
            if !img.attrOrEmpty("data-lazy-src").isEmpty { dataLazySrc += 1 }
            if !img.attrOrEmpty("data-src").isEmpty { dataSrc += 1 }
            if HTMLKit.allAttributes(img).contains(where: { $0.name == "data-ll-status" }) { llStatus = true }
            let cls = img.attrOrEmpty("class")
            if cls.range(of: #"(^|\s)lazy(\s|$)"#, options: .regularExpression) != nil
                || cls.range(of: #"(^|\s)lazyload(ed)?(\s|$)"#, options: .regularExpression) != nil { lazyClass = true }
            let s = img.attrOrEmpty("src").trimmingCharacters(in: .whitespaces)
            if !s.isEmpty { srcCount[s, default: 0] += 1 }
        }
        // gêmeo: o MESMO src (placeholder) em 3+ imagens, com um data-*
        // trazendo URLs distintos — o gêmeo é a URL real
        var twinAttr = ""
        for (s, count) in srcCount where count >= 3 && twinAttr.isEmpty {
            var twins: [String: Set<String>] = [:]
            for img in imgs where img.attrOrEmpty("src").trimmingCharacters(in: .whitespaces) == s {
                for at in HTMLKit.allAttributes(img) where at.name.hasPrefix("data-") && at.name != "data-ll-status" {
                    let v = at.value.trimmingCharacters(in: .whitespaces)
                    let first = v.split(separator: ",").first?
                        .split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
                    if !v.isEmpty, looksLikeImageUrl(first), !isPlaceholderSrc(v) {
                        twins[at.name, default: []].insert(v)
                    }
                }
            }
            for (name, set) in twins where set.count >= 3 {
                twinAttr = name
                break
            }
        }
        var signals: [String] = []
        if dataLazySrc > 0 { signals.append("data-lazy-src em \(dataLazySrc) img(s)") }
        if dataSrc > 0 { signals.append("data-src em \(dataSrc) img(s)") }
        if llStatus { signals.append("data-ll-status (loader lazy já rodou — colagem renderizada)") }
        if lazyClass { signals.append("classe \"lazy\" em img(s)") }
        if !twinAttr.isEmpty { signals.append("src repetido com gêmeo \(twinAttr) de URLs distintos — o gêmeo vence") }
        let present = dataLazySrc > 0 || dataSrc > 0 || llStatus || lazyClass || !twinAttr.isEmpty
        return (present, dataLazySrc, dataSrc, signals)
    }

    // MARK: analyzeList — o fluxo do web

    static func analyzeList(inputs: YegenInputs) -> ListAnalysis? {
        guard let doc = parse(inputs.listHTML) else { return nil }
        var result = ListAnalysis()
        let origin = siteOrigin(inputs)
        let ctx = TrioCtx(origin: origin, detailExampleUrl: inputs.detailUrl)

        // Agrupamento por assinatura (tag+classes) em TODO o documento —
        // só elementos com link E alguma variável de capa/script dentro.
        let markerSel = "img,[data-img-url],video[poster],picture,[style*='background-image'],[data-src],[data-original],[data-lazy-src],[data-thumb],[data-cover],script"
        var groups: [String: [Element]] = [:]
        var groupOrder: [String] = []
        for el in HTMLKit.descendants(of: doc) {
            if el.tagName() == "html" || el.tagName() == "head" || el.tagName() == "body" { continue }
            if HTMLKit.select(el, "a").isEmpty { continue }
            if HTMLKit.select(el, markerSel).isEmpty { continue }
            let sig = HTMLKit.signature(el)
            if groups[sig] == nil { groupOrder.append(sig) }
            groups[sig, default: []].append(el)
        }
        // Passo de família (v3.13): os órfãos viram grupos derivados.
        var famAdded: [String: [Element]] = [:]
        for fg in familyGroups(doc: doc, groups: groups, ctx: ctx) {
            let key = "fam|" + fg.selector
            famAdded[key] = fg.els
            groups[key] = fg.els
            groupOrder.append(key)
        }

        var minCount = 5
        var cands: [BlockGroup] = []
        for key in groupOrder {
            guard let els = groups[key], els.count >= minCount, let first = els.first else { continue }
            let sel = famAdded[key] != nil ? key.replacingOccurrences(of: "fam|", with: "")
                : HTMLKit.buildSelector(first)
            cands.append(BlockGroup(selector: sel, els: els))
        }
        // Resgate semântico: grupo article/post com 3–4 itens entra mesmo assim
        do {
            for key in groupOrder {
                guard let els = groups[key], els.count >= 3, els.count < minCount else { continue }
                if cands.contains(where: { $0.els.first === els.first }) { continue }
                let probe = BlockGroup(selector: "", els: els)
                if isSemanticGroup(probe, ctx: ctx), let first = els.first {
                    let sel = famAdded[key] != nil ? key.replacingOccurrences(of: "fam|", with: "")
                        : HTMLKit.buildSelector(first)
                    cands.append(BlockGroup(selector: sel, els: els))
                }
            }
        }
        if cands.isEmpty {
            minCount = 3
            for key in groupOrder {
                guard let els = groups[key], els.count >= minCount, let first = els.first else { continue }
                let sel = famAdded[key] != nil ? key.replacingOccurrences(of: "fam|", with: "")
                    : HTMLKit.buildSelector(first)
                cands.append(BlockGroup(selector: sel, els: els))
            }
        }
        // Dedup aninhado: mesmo tamanho e itens de um dentro do outro —
        // fica o de fora (só com poucos candidatos: o dedup é quadrático)
        cands.sort { $0.els.count > $1.els.count }
        var filtered: [BlockGroup] = []
        if cands.count <= 24 {
            for g in cands {
                let nested = filtered.contains { f in
                    f.els.count == g.els.count && g.els.allSatisfy { el in
                        f.els.contains { fe in fe !== el && isAncestor(fe, of: el) }
                    }
                }
                if !nested { filtered.append(g) }
            }
        } else {
            filtered = cands
        }
        cands = Array(filtered.prefix(8))
        // Resgate semântico FORA do corte estrutural
        for g in filtered where !cands.contains(where: { $0 === g }) {
            if isSemanticGroup(g, ctx: ctx), cands.count < 12 { cands.append(g) }
        }
        // Seletor robusto (v1.8) + fusão das variantes que viram o mesmo
        for g in cands { robustify(doc: doc, group: g) }
        var merged: [BlockGroup] = []
        for g in cands {
            if let tgt = merged.first(where: { $0.selector == g.selector }) {
                let seen = Set(tgt.els.map { ObjectIdentifier($0) })
                for e in g.els where !seen.contains(ObjectIdentifier(e)) { tgt.els.append(e) }
            } else {
                merged.append(g)
            }
        }
        cands = merged
        // Detector de blocos: mesmo conjunto → o seletor do bloco (pai >
        // filho) é o específico e seguro; senão o bloco entra como candidato
        for b in detectBlocks(doc: doc, ctx: ctx) {
            if let dup = cands.first(where: { $0.selector == b.selector
                || ($0.els.count == b.els.count && $0.els.first === b.els.first) }) {
                dup.selector = b.selector
                dup.isBlock = true
                if let st = b.statsPct { dup.statsPct = st }
            } else {
                cands.append(b)
            }
        }
        // Padrão item-âncora: mesma cobertura → fica o de maior completude
        for b in detectAnchorItems(doc: doc, ctx: ctx) {
            if let idx = cands.firstIndex(where: { sameItemCoverage($0, b) }) {
                if candidateCompleteness(b, ctx: ctx) > candidateCompleteness(cands[idx], ctx: ctx) {
                    cands[idx] = b
                }
            } else {
                cands.append(b)
            }
        }
        guard !cands.isEmpty else {
            result.notes.append("nenhum candidato a item encontrado — nem por classe, nem pelo detector de blocos, nem como item-âncora (confira se colou o HTML da página de lista)")
            return result
        }
        // Pontuação por candidato (amostra de até 10 itens)
        for g in cands {
            guard let first = g.els.first else { continue }
            let t = ctx.title(first)
            let c = ctx.cover(first)
            let idc = ctx.idCode(first)
            g.title = t
            g.cover = c
            g.idc = idc
            let sample = Array(g.els.prefix(10))
            var wc = 0, wt = 0, wl = 0
            for el in sample {
                if ctx.cover(el) != nil { wc += 1 }
                if ctx.title(el) != nil { wt += 1 }
                if ctx.idCode(el) != nil { wl += 1 }
            }
            if g.statsPct == nil {
                g.statsPct = (Int((Double(wc) / Double(sample.count) * 100).rounded()),
                              Int((Double(wt) / Double(sample.count) * 100).rounded()),
                              Int((Double(wl) / Double(sample.count) * 100).rounded()))
            }
            var score = g.els.count
            if t != nil { score += 20 }
            if let c, !c.value.isEmpty { score += 15 }
            if idc != nil { score += 10 }
            if let c, c.lazy { score += 2 }
            if g.isBlock { score += 5 }
            g.score = scoreAdjust(g, base: score, ctx: ctx)
        }
        // Guardas anti-pseudo-item (v3.11) e ordenação final
        applyListGuards(cands, ctx: ctx)
        cands.sort { $0.score > $1.score }
        // Portão (v3.7): pré-seleção = melhor que passa no clique
        let gate = gatePick(cands)
        let g = cands[gate.idx]
        if gate.fallback { result.notes.append(gate.reason) }
        result.notes += g.guardNotes
        if g.blogroll { result.notes.append("bloco com maioria de links externos (blogroll/parceiros) — pontuação reduzida") }
        if g.isLateral { result.notes.append("bloco em área lateral (aside/widget/sidebar) — pontuação reduzida") }

        // Aplicação do bloco: estabilizar campos, minimizar o idCode,
        // face lazy — nesta ordem, como o web.
        var applyNotes: [String] = []
        stabilizeFields(g, ctx: ctx, notes: &applyNotes)
        minimizeIdCode(g, ctx: ctx, notes: &applyNotes)
        result.notes += applyNotes
        let face = lazyFace(of: g.els)
        if face.present {
            result.notes.append("face lazy detectada: " + face.signals.joined(separator: "; "))
            if face.dataLazySrc > 0, var cov = g.cover {
                cov.param = "data-lazy-src, src"
                g.cover = cov
            }
        }

        result.itemSelector = HTMLKit.sanitizeSelector(g.selector)
        if let first = g.els.first {
            result.itemSignature = HTMLKit.signature(first)
        }
        result.itemCount = g.els.count
        // Amostras + métricas do "teste estrito" da UI (extração de
        // verdade, campo a campo, nos 8 primeiros itens)
        let sample = Array(g.els.prefix(8))
        if let t = g.title {
            result.titleField = t.field
            result.titleSample = t.sample
            var ok = 0
            for it in sample {
                if let v = HTMLKit.extract(t.field, in: it), v.count >= 2 { ok += 1 }
            }
            result.strictTitle = "\(ok)/\(sample.count)"
        }
        if let c = g.cover {
            result.coverField = c.field
            result.coverSample = c.value
            var ok = 0
            for it in sample {
                if let v = HTMLKit.extract(c.field, in: it),
                   looksLikeImageUrl(v), !isPlaceholderSrc(v) { ok += 1 }
            }
            result.strictCover = "\(ok)/\(sample.count)"
        }
        if let idc = g.idc {
            result.idCodeField = idc.field
            result.idCodeSample = idc.finalUrl
            var ok = 0
            var urls: [String] = []
            for it in sample {
                if let v = HTMLKit.extract(idc.field, in: it) {
                    urls.append(v)
                    if validateFinalUrl(v, origin: origin) { ok += 1 }
                }
            }
            result.strictIdCode = "\(ok)/\(sample.count)"
            result.detailSamples = urls
        }
        if result.titleField == nil { result.notes.append("título não detectado no bloco escolhido") }
        if result.coverField == nil { result.notes.append("capa não detectada no bloco escolhido") }
        if result.idCodeField == nil { result.notes.append("idCode não detectado no bloco escolhido") }
        return result
    }


    // MARK: - Análise do DETALHE

    // MARK: - Detalhe: título e capa (porte web v3.7 (C)/(D) + v3.20)

    /// pickDetailH1 do web: o h1 do POST, não o do site — bônus
    /// entry-title/post-title (+100), penalidade site-title/site-logo/
    /// logo/brand (−60), + tamanho do texto (máx. 40). Só h1 com texto.
    private static func pickDetailH1(_ doc: Document) -> (selector: String, text: String)? {
        var best: (el: Element, s: Int, text: String)? = nil
        for el in HTMLKit.select(doc, "h1") {
            let tx = el.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
            if tx.isEmpty { continue }
            let cls = el.attrOrEmpty("class")
            var s = 0
            if cls.range(of: "entry-title|post-title", options: .regularExpression) != nil { s += 100 }
            if cls.range(of: "site-title|site-logo|logo|brand", options: .regularExpression) != nil { s -= 60 }
            s += min(tx.count, 40)
            if best == nil || s > best!.s { best = (el, s, tx) }
        }
        guard let b = best else { return nil }
        return (HTMLKit.sanitizeSelector(HTMLKit.buildSelector(b.el)), b.text)
    }

    /// Fonte (3) do título: h2.entry-title/post-title, .entry-title,
    /// .post-title ou o primeiro h2 com texto ≥ 3.
    private static func detailAltTitle(_ doc: Document) -> FieldRule? {
        guard let el = HTMLKit.first(doc, "h2.entry-title, h2.post-title, .entry-title, .post-title, h2")
        else { return nil }
        let t = el.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 3 else { return nil }
        return FieldRule(selector: HTMLKit.sanitizeSelector(HTMLKit.buildSelector(el)), function: "text")
    }

    /// Fonte (4) do título: o slug da URL — field sobre o canonical com
    /// regex host/(.+?)/?$; sem canonical, usa a URL de detalhe digitada
    /// (o mesmo campo que o web usa de reserva).
    private static func slugTitleField(inputs: YegenInputs, doc: Document, origin: String)
        -> (field: FieldRule, sample: String)? {
        var href = ""
        if let can = HTMLKit.first(doc, "link[rel='canonical']") { href = can.attrOrEmpty("href") }
        if href.isEmpty { href = inputs.detailUrl }
        if href.isEmpty { return nil }
        let resolved = HTMLKit.absolutize(href, origin: origin)
        let host = HTMLKit.host(of: resolved)
        if host.isEmpty { return nil }
        let escaped = NSRegularExpression.escapedPattern(for: host)
        let pattern = escaped + "/(.+?)/?$"
        let field = FieldRule(selector: "link[rel='canonical']", function: "attr", param: "href",
                              regex: pattern, replacement: "$1")
        let sample = HTMLKit.firstCapture(pattern, in: href, replacement: "$1") ?? ""
        return (field, sample)
    }

    /// detailContentCover37 do web: fallback de capa SEM og:image.
    /// (1) poster do PRÓPRIO player; (1b) "poster"/"pic" na config do
    /// player (script); (2) imagem de conteúdo fora do rail de
    /// relacionados (guarda v3.20), fora de aside/header/footer/nav, sem
    /// placeholder e sem cara de logo/avatar/ícone; (3) nada.
    private static func detailContentCover(doc: Document, raw: String, list: ListAnalysis?, origin: String)
        -> (field: FieldRule?, sample: String, source: String, rejected: Int) {
        var rejected = 0
        let itemSel = list?.itemSelector ?? ""
        let itemSig = list?.itemSignature ?? ""
        var itemSelMatches = Set<ObjectIdentifier>()
        var itemSelCount = 0
        if !itemSel.isEmpty {
            let ms = HTMLKit.select(doc, itemSel)
            itemSelCount = ms.count
            itemSelMatches = Set(ms.map { ObjectIdentifier($0) })
        }
        // Um elemento está no rail se ele (ou um ancestral) casa com o
        // seletor de item da lista OU tem a mesma assinatura do item —
        // E esse bloco se repete ≥ 2× no detalhe (o invólucro único do
        // próprio conteúdo, ex. o <article> do post, não é rail).
        func blockedByRail(_ el: Element) -> Bool {
            if itemSel.isEmpty && itemSig.isEmpty { return false }
            var node: Element? = el
            while let n = node, n.tagName() != "body", n.tagName() != "html" {
                var why = false
                if !itemSel.isEmpty, itemSelMatches.contains(ObjectIdentifier(n)) { why = true }
                if !why, !itemSig.isEmpty, HTMLKit.signature(n) == itemSig { why = true }
                if why {
                    var cnt = itemSelCount
                    if cnt < 2, !itemSig.isEmpty {
                        cnt = HTMLKit.descendants(of: doc).filter {
                            $0.tagName() == n.tagName() && HTMLKit.signature($0) == itemSig
                        }.count
                    }
                    if cnt >= 2 { return true }
                }
                node = n.parent()
            }
            return false
        }
        // (1) poster do PRÓPRIO player do detalhe (<video poster>)
        if let vid = HTMLKit.select(doc, "video[poster]").first(where: { !$0.attrOrEmpty("poster").isEmpty }) {
            let pv = vid.attrOrEmpty("poster").trimmingCharacters(in: .whitespaces)
            if !pv.isEmpty, !isPlaceholderSrc(pv) {
                if blockedByRail(vid) {
                    rejected += 1
                } else {
                    let vsel = HTMLKit.selForEl(vid)
                    return (FieldRule(selector: vsel, function: "attr", param: "poster"),
                            pv, "poster do próprio player do detalhe (<video poster>)", rejected)
                }
            }
        }
        // (1b) poster/pic na CONFIG do player (script) — ex.: o "pic" do player_aaaa
        let cfgPatterns = [#""(?:poster|pic)"\s*:\s*"(https?:[^"]+?\.(?:jpe?g|png|webp)[^"]*)""#,
                           #"(?:poster|pic)\s*[:=]\s*"(https?:[^"]+?\.(?:jpe?g|png|webp)[^"]*)""#]
        for pat in cfgPatterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.caseInsensitive]),
                  let m = re.firstMatch(in: raw, options: [], range: NSRange(raw.startIndex..., in: raw)),
                  let r1 = Range(m.range(at: 1), in: raw) else { continue }
            let url = String(raw[r1])
            if isPlaceholderSrc(url) { continue }
            let whole = Range(m.range, in: raw).map { String(raw[$0]) } ?? ""
            let key = (whole.range(of: #""pic"\s*:"#, options: .regularExpression) != nil
                       || whole.hasPrefix("pic")) ? "pic" : "poster"
            let field = FieldRule(selector: "script", function: "text",
                                  regex: "\"" + key + "\"\\s*:\\s*\"([^\"]+)\"", replacement: "$1")
            return (field, url, "config do próprio player do detalhe (\"\(key)\" no script)", rejected)
        }
        // (2) imagem de conteúdo fora de blocos-lista/relacionados
        var imgs = HTMLKit.select(doc, "article img, main img, .entry-content img, .post-content img, [class*='content'] img")
        if imgs.isEmpty { imgs = HTMLKit.select(doc, "img") }
        for im in imgs {
            if blockedByRail(im) { rejected += 1; continue }
            if elLateral(im) { continue }
            var inChrome = false
            var anc = im.parent()
            while let a = anc {
                if ["header", "footer", "nav"].contains(a.tagName()) { inChrome = true; break }
                anc = a.parent()
            }
            if inChrome { continue }
            let cov = classicCover(of: im)
            let rawVal = cov?.value ?? (!im.attrOrEmpty("src").isEmpty ? im.attrOrEmpty("src") : im.attrOrEmpty("data-src"))
            if rawVal.isEmpty || isPlaceholderSrc(rawVal) { continue }
            if rawVal.range(of: "logo|avatar|icon|sprite|gravatar",
                            options: [.regularExpression, .caseInsensitive]) != nil { continue }
            var cont: Element? = im.parent()
            while let c = cont, !["article", "main", "div", "figure", "section"].contains(c.tagName()) {
                cont = c.parent()
            }
            let sel = cont != nil ? HTMLKit.selForEl(cont!) + " img" : "img"
            return (FieldRule(selector: sel, function: "attr", param: cov?.attr ?? "src"),
                    rawVal, "imagem de conteúdo fora de blocos-lista/relacionados", rejected)
        }
        // (3) sem capa própria segura — o chamador NÃO emite cover
        return (nil, "", "", rejected)
    }

    static func analyzeDetail(inputs: YegenInputs, list: ListAnalysis?) -> DetailAnalysis? {
        guard let doc = parse(inputs.detailHTML) else { return nil }
        var result = DetailAnalysis()
        let origin = siteOrigin(inputs)

        // ---- Título (web v3.7 (C)): ordem de fontes — (1) h1 pontuado,
        // (2) og:title, (3) outro elemento, (4) slug da URL (último recurso)
        if let h1 = pickDetailH1(doc) {
            result.titleField = FieldRule(selector: h1.selector, function: "text")
            result.titleSample = h1.text
        } else if let ogTitle = HTMLKit.metaContent(doc, property: "og:title") {
            result.titleField = FieldRule(selector: "meta[property=\"og:title\"]",
                                          function: "attr", param: "content")
            result.titleSample = ogTitle
        } else if let alt = detailAltTitle(doc) {
            result.titleField = alt
            result.titleSample = HTMLKit.extract(alt, in: doc) ?? ""
        } else if let slug = slugTitleField(inputs: inputs, doc: doc, origin: origin) {
            result.titleField = slug.field
            result.titleSample = slug.sample
            result.notes.append("título do detalhe pela URL (slug) — último recurso: sem heading nem og:title no HTML")
        } else {
            result.notes.append("sem h1, sem og:title e sem slug aproveitável no detalhe")
        }

        // ---- Capa (web v3.7 (D) + v3.20 (1)): og:image presente manda;
        // sem ela, o fallback detailContentCover — poster do próprio
        // player > "pic"/"poster" da config > imagem de conteúdo fora do
        // rail de relacionados; nada seguro = detalhe sem cover.
        if let ogImage = HTMLKit.metaContent(doc, property: "og:image") {
            result.coverCandidate = FieldRule(selector: "meta[property=\"og:image\"]",
                                              function: "attr", param: "content")
            result.coverSample = HTMLKit.absolutize(ogImage, origin: origin)
            result.coverSource = "og:image"
        } else {
            let cc = detailContentCover(doc: doc, raw: inputs.detailHTML, list: list, origin: origin)
            if let fld = cc.field {
                result.coverCandidate = fld
                result.coverSample = HTMLKit.absolutize(cc.sample, origin: origin)
                result.coverSource = cc.source
            } else {
                result.notes.append("sem og:image e sem capa de conteúdo segura — detalhe sai sem cover")
            }
            if cc.rejected > 0 {
                result.notes.append("\(cc.rejected) imagem(ns) ignorada(s) por estarem no rail de relacionados")
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

    // MARK: - Tags do detalhe (porte do detectTagCandidates do web)

    private struct TagCand {
        var selector: String
        var anchors: [Element]
        var score: Double
    }

    /// routeKeyOf do web: o primeiro segmento do caminho (sem index.php).
    private static func routeKey(of urlString: String, origin: String) -> String {
        if urlString.isEmpty { return "" }
        let resolved = resolveForCompare(urlString, origin: origin)
        var segs = TrioCtx.pathSegments(of: resolved)
        if let first = segs.first, first.lowercased() == "index.php" { segs.removeFirst() }
        guard let first = segs.first else { return "" }
        return (first.removingPercentEncoding ?? first).lowercased()
    }

    /// detectTagCandidates do web (v3.3 (C) + v3.7 (E)): candidatos de
    /// bloco de tags pontuados — rota dominante, bloco em <strong>
    /// (relacionadas), posição no miolo, penalidade de lateral, bônus
    /// rel="tag"/entry-meta. O nativo guarda UM bloco (o vencedor); a
    /// tupla url sai da lógica de emissão que ele já usava.
    private static func detectTags(doc: Document, list: ListAnalysis?, origin: String,
                                   result: inout DetailAnalysis) {
        let allA = HTMLKit.select(doc, "a[href]")
        if allA.isEmpty { return }
        func inStrong(_ a: Element) -> Bool {
            var cur: Element? = a
            while let c = cur {
                if c.tagName() == "strong" { return true }
                cur = c.parent()
            }
            return false
        }
        func inChrome(_ a: Element) -> Bool {
            var cur: Element? = a
            while let c = cur {
                if ["header", "footer", "nav"].contains(c.tagName()) { return true }
                cur = c.parent()
            }
            return false
        }
        var cands: [TagCand] = []
        var seenSel = Set<String>()
        func mkCand(_ selector: String, _ anchors: [Element], _ strongBlock: Bool) {
            if anchors.isEmpty || seenSel.contains(selector) { return }
            seenSel.insert(selector)
            var routes: [String: Int] = [:]
            var domN = 0
            for a in anchors {
                let rk = routeKey(of: a.attrOrEmpty("href"), origin: origin)
                let key = rk.isEmpty ? "(home)" : rk
                routes[key, default: 0] += 1
                domN = max(domN, routes[key] ?? 0)
            }
            let share = Double(domN) / Double(anchors.count)
            let strongN = anchors.filter { inStrong($0) }.count
            let allStrong = strongN > 0 && strongN == anchors.count
            let posIdx = anchors.first.flatMap { fa in allA.firstIndex(where: { $0 === fa }) } ?? 0
            let posFrac = Double(posIdx) / Double(allA.count)
            let chrome = anchors.first.map { inChrome($0) } ?? false
            var latN = 0, relN = 0
            for a in anchors.prefix(12) {
                if elLateral(a) { latN += 1 }
                let relTokens = a.attrOrEmpty("rel").split(separator: " ").map(String.init)
                var inMeta = false
                var cur: Element? = a
                while let c = cur {
                    if HTMLKit.classesInOrder(c).contains("entry-meta") { inMeta = true; break }
                    cur = c.parent()
                }
                if relTokens.contains("tag") || inMeta { relN += 1 }
            }
            let latFrac = Double(latN) / Double(min(12, anchors.count))
            let lateral = latFrac >= 0.5
            var score = share * 40
                + ((strongBlock || allStrong) ? 50 : (strongN > 0 ? 20 : 0))
                + ((posFrac >= 0.08 && posFrac <= 0.92 && !chrome) ? 15 : 0)
                - Double(max(0, anchors.count - 60)) / 8
            if lateral { score -= 60 }
            if relN > 0 { score += 45 }
            cands.append(TagCand(selector: selector, anchors: anchors, score: score))
        }
        // Contêineres com cara de tag/categoria/gênero
        let containers = HTMLKit.select(doc, "[class*='tag'], [id*='tag'], [class*='categor'], [id*='categor'], .entry-tags, .post-tags, [class*='genre'], [rel='tag']")
        for c in containers {
            let links = c.tagName() == "a" ? [c] : HTMLKit.select(c, "a[href]")
            if links.isEmpty { continue }
            let base = c.tagName() == "a"
                ? HTMLKit.buildSelector(c.parent() ?? c)
                : HTMLKit.buildSelector(c)
            mkCand(base + " a", links, false)
            let sl = links.filter { inStrong($0) }
            if sl.count >= 2 && sl.count < links.count { mkCand(base + " strong a", sl, true) }
        }
        // Genérico: âncoras repetidas sob o mesmo pai (assinatura do pai)
        var groupSel: [String: String] = [:]
        var groupEls: [String: [Element]] = [:]
        var groupOrder: [String] = []
        for a in allA {
            guard let p = a.parent() else { continue }
            let key = HTMLKit.signature(p) + ">a"
            if groupEls[key] == nil {
                groupOrder.append(key)
                groupSel[key] = HTMLKit.buildSelector(p) + " a"
            }
            groupEls[key, default: []].append(a)
        }
        for key in groupOrder {
            guard let els = groupEls[key], els.count >= 4, let sel = groupSel[key] else { continue }
            let names = els.prefix(6)
                .map { $0.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if names.count >= 3, names.allSatisfy({ $0.count <= 40 }) {
                mkCand(sel, els, false)
                let sl2 = els.filter { inStrong($0) }
                if sl2.count >= 2 && sl2.count < els.count {
                    mkCand(String(sel.dropLast(2)) + " strong a", sl2, true)
                }
            }
        }
        cands.sort { $0.score != $1.score ? $0.score > $1.score : $0.anchors.count > $1.anchors.count }
        guard let best = cands.first, let first = best.anchors.first else { return }
        result.tagItemSelector = best.selector
        result.tagField = tagFieldFor(firstHref: first.attrOrEmpty("href"), origin: origin)
        result.tagCount = best.anchors.count
        result.tagSample = first.textOrEmpty().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A tupla url das tags a partir do href do 1º item (a lógica de
    /// emissão que o nativo já usava: absoluta, relativa ou .html com
    /// pageFormat de caminho).
    private static func tagFieldFor(firstHref: String, origin: String) -> FieldRule {
        if firstHref.hasPrefix("http://") || firstHref.hasPrefix("https://") {
            return FieldRule(selector: "this", function: "attr", param: "href",
                             regex: "(.+)", replacement: "$1")
        } else if firstHref.hasSuffix(".html") {
            return FieldRule(selector: "this", function: "attr", param: "href",
                             regex: #"(.+)\.html"#,
                             replacement: origin + "$1" + "{pageFormat:/page/{page:}}.html")
        } else if firstHref.hasPrefix("/") {
            return FieldRule(selector: "this", function: "attr", param: "href",
                             regex: "(.+)", replacement: origin + "$1")
        }
        return FieldRule(selector: "this", function: "attr", param: "href",
                         regex: "(.+)", replacement: origin + "/$1")
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
