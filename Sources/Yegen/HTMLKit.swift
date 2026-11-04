import Foundation
import SwiftSoup

/// Utilidades sobre o SwiftSoup + regex — o "modo estrito" do Yealico:
/// toda extração é testada do mesmo jeito que o app lê (selector dentro
/// do contexto, function/param, regex com replacement "$1").
enum HTMLKit {

    // MARK: Seletores seguros (nunca derrubam a análise)

    static func select(_ el: Element, _ css: String) -> [Element] {
        (try? el.select(css))?.array() ?? []
    }

    static func first(_ el: Element, _ css: String) -> Element? {
        select(el, css).first
    }

    static func metaContent(_ doc: Document, property: String) -> String? {
        let metas = doc.getElementsByAttributeValue("property", property).array()
        for m in metas {
            let v = m.attr("content")
            if !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: Assinatura de bloco

    /// Assinatura estrutural de um elemento: tag + classes ordenadas.
    /// É ela que agrupa os itens repetidos da lista.
    static func signature(_ el: Element) -> String {
        let classes = el.classNames().sorted()
        if classes.isEmpty { return el.tagName() }
        return el.tagName() + "." + classes.joined(separator: ".")
    }

    /// Seletor CSS a partir da assinatura (tag.classe1.classe2).
    static func selector(forSignature sig: String) -> String { sig }

    /// Nome de tag/classe "estável": sem lixo dinâmico (floats, hashes).
    static func isStableToken(_ s: String) -> Bool {
        if s.isEmpty || s.count > 40 { return false }
        return s.range(of: "^[A-Za-z][A-Za-z0-9_-]*$", options: .regularExpression) != nil
    }

    /// Seletor curto pra um elemento: tag#id estável, tag.classe estável
    /// ou a tag pura (a lei do seletor mínimo começa aqui).
    static func shortSelector(_ el: Element) -> String {
        let tag = el.tagName()
        let id = el.attr("id")
        if !id.isEmpty && isStableToken(id) { return "\(tag)#\(id)" }
        let classes = el.classNames().sorted()
        if let c = classes.first(where: { isStableToken($0) }) {
            return "\(tag).\(c)"
        }
        return tag
    }

    /// Seletor de um descendente RELATIVO ao item: a forma mais curta
    /// cujo PRIMEIRO resultado dentro do item é o próprio alvo.
    static func relativeSelector(item: Element, target: Element) -> String {
        if target === item { return "this" }
        let seg = shortSelector(target)
        if first(item, seg) === target { return seg }
        if let parent = target.parent() {
            let combined = shortSelector(parent) + " " + seg
            if first(item, combined) === target { return combined }
            return combined
        }
        return seg
    }

    // MARK: Regex (padrão do guia dele: captura + replacement com $N)

    static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [])
    }

    /// Expande o replacement: $1, $2… viram os grupos da captura;
    /// o resto do texto é literal (sem a semântica de template do
    /// NSRegularExpression, que brigaria com chaves e afins).
    static func expand(_ replacement: String, match: NSTextCheckingResult, in text: String) -> String {
        var out = ""
        var i = replacement.startIndex
        while i < replacement.endIndex {
            let ch = replacement[i]
            if ch == "$" {
                let next = replacement.index(after: i)
                if next < replacement.endIndex, replacement[next].isNumber {
                    var numStr = ""
                    var j = next
                    while j < replacement.endIndex, replacement[j].isNumber {
                        numStr.append(replacement[j])
                        j = replacement.index(after: j)
                    }
                    if let g = Int(numStr), g <= match.numberOfRanges - 1 {
                        let r = match.range(at: g)
                        if r.location != NSNotFound,
                           let sr = Range(r, in: text) {
                            out += text[sr]
                        }
                    }
                    i = j
                    continue
                }
            }
            out.append(ch)
            i = replacement.index(after: i)
        }
        return out
    }

    /// Primeira captura do padrão no texto, já com o replacement aplicado.
    static func firstCapture(_ pattern: String, in text: String, replacement: String) -> String? {
        guard let re = regex(pattern) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, options: [], range: range) else { return nil }
        return expand(replacement, match: m, in: text)
    }

    /// Executa um campo-regex sobre um texto cru (corpo da página):
    /// aplica a regex e, se a function é a cadeia do guia
    /// (html.regexReplacement.replace("\/", with: "/")), desescapa as
    /// barras no resultado.
    static func applyBodyField(_ field: FieldRule, rawText: String) -> String? {
        guard let pattern = field.regex, let repl = field.replacement else { return nil }
        var result = firstCapture(pattern, in: rawText, replacement: repl)
        if let f = field.function, f.contains(".replace("), f.contains("\\/") {
            result = result?.replacingOccurrences(of: "\\/", with: "/")
        }
        return result
    }

    // MARK: Extração estrita de campo dentro de um elemento

    /// Extrai o valor de um campo DENTRO do contexto (o item, o detalhe):
    /// "this" = o próprio contexto; function attr tenta os params na
    /// ordem (data-src, src); text = texto do elemento.
    static func extract(_ field: FieldRule, in context: Element) -> String? {
        let target: Element?
        if field.selector == "this" {
            target = context
        } else {
            target = first(context, field.selector)
        }
        guard let el = target else { return nil }

        var value: String?
        switch field.function {
        case "attr":
            let params = (field.param ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            for p in params where !p.isEmpty {
                let v = el.attr(p)
                if !v.isEmpty { value = v; break }
            }
        case "text":
            value = el.text()
        case "html":
            value = try? el.html()
        default:
            // Sem function (ou cadeia de regex): o regex roda sobre o
            // HTML do elemento selecionado.
            if field.regex != nil {
                let raw = (try? el.outerHtml()) ?? ""
                return applyBodyField(field, rawText: raw)
            }
            value = el.text()
        }
        guard var v = value else { return nil }
        if let pattern = field.regex, let repl = field.replacement,
           field.function == "attr" || field.function == "text" {
            v = firstCapture(pattern, in: v, replacement: repl) ?? v
        }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: URLs

    /// Origem (scheme + host + porta) de uma URL, com "/" no fim.
    static func origin(of urlString: String) -> String {
        guard let url = URL(string: urlString), let scheme = url.scheme, let host = url.host else {
            return ""
        }
        var o = "\(scheme)://\(host)"
        if let port = url.port { o += ":\(port)" }
        return o
    }

    /// Absolutiza um href contra a origem do site.
    static func absolutize(_ href: String, origin: String) -> String {
        if href.hasPrefix("http://") || href.hasPrefix("https://") { return href }
        if href.hasPrefix("//") { return "https:" + href }
        if href.hasPrefix("/") { return origin + href }
        return origin + "/" + href
    }

    static func host(of urlString: String) -> String {
        URL(string: urlString)?.host ?? ""
    }
}
