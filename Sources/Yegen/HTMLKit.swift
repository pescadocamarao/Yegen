import Foundation
import SwiftSoup

/// Acessores NÃO-lançantes sobre o SwiftSoup atual (2.14.x).
/// Na linha 2.10+ do SwiftSoup, `attr(_:)`, `text()` e `classNames()`
/// viraram `throws` — e o SPM resolve a maior 2.x a partir do
/// `from: "2.6.0"` do project.yml. Estes wrappers restauram a semântica
/// antiga que o motor pressupõe (ausente/falha = vazio), com o mesmo
/// comportamento dos acessores pré-2.10: attr ausente devolvia "" e
/// text() de elemento vazio devolvia "".
extension Element {
    /// Equivalente seguro de `attr(_:)`: "" quando o atributo não existe.
    func attrOrEmpty(_ key: String) -> String {
        (try? attr(key)) ?? ""
    }

    /// Equivalente seguro de `text()`: "" quando não há texto.
    func textOrEmpty() -> String {
        (try? text()) ?? ""
    }

    /// Equivalente seguro de `classNames()`: classes ordenadas
    /// (o original devolve OrderedSet; o motor sempre ordenou em seguida).
    func classNamesOrEmpty() -> [String] {
        ((try? classNames())?.sorted()) ?? []
    }
}

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
        let metas = (try? doc.getElementsByAttributeValue("property", property))?.array() ?? []
        for m in metas {
            let v = m.attrOrEmpty("content")
            if !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: Assinatura de bloco

    /// Assinatura estrutural de um elemento: tag + classes ordenadas.
    /// É ela que agrupa os itens repetidos da lista.
    static func signature(_ el: Element) -> String {
        let classes = el.classNamesOrEmpty().sorted()
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
        let id = el.attrOrEmpty("id")
        if !id.isEmpty && isStableToken(id) { return "\(tag)#\(id)" }
        let classes = el.classNamesOrEmpty().sorted()
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
                let v = el.attrOrEmpty(p)
                if !v.isEmpty { value = v; break }
            }
        case "text":
            value = el.textOrEmpty()
        case "html":
            value = try? el.html()
        default:
            // Sem function (ou cadeia de regex): o regex roda sobre o
            // HTML do elemento selecionado.
            if field.regex != nil {
                let raw = (try? el.outerHtml()) ?? ""
                return applyBodyField(field, rawText: raw)
            }
            value = el.textOrEmpty()
        }
        guard var v = value else { return nil }
        if let pattern = field.regex, let repl = field.replacement,
           field.function == "attr" || field.function == "text" {
            v = firstCapture(pattern, in: v, replacement: repl) ?? v
        }
        let trimmed = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: Porte do motor web (v1.1) — equivalentes estruturais do DOM

    /// Classes na ORDEM do atributo (o `classesOf` do web preserva a
    /// ordem; o classNames() do SwiftSoup devolve conjunto ordenado).
    static func classesInOrder(_ el: Element) -> [String] {
        el.attrOrEmpty("class")
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .map(String.init)
    }

    /// O elemento + todos os descendentes, em ordem de documento
    /// (o getAllElements já devolve nessa ordem, com o próprio primeiro).
    static func descendants(of el: Element) -> [Element] {
        (try? el.getAllElements())?.array() ?? [el]
    }

    /// Filhos DIRETOS (o `children` do DOM): descendentes cujo pai é o
    /// próprio elemento — derivado do getAllElements, sem API nova.
    static func directChildren(of el: Element) -> [Element] {
        descendants(of: el).filter { $0 !== el && $0.parent() === el }
    }

    /// Todos os atributos do elemento (nome → valor), enumerados da tag
    /// de abertura do outerHtml — o SwiftSoup não expõe uma enumeração
    /// pública estável de atributos; os valores voltam com as entidades
    /// básicas desescapadas (&amp; &quot; &#39; &lt; &gt;), como o
    /// getAttribute do navegador devolve.
    static func allAttributes(_ el: Element) -> [(name: String, value: String)] {
        guard let html = try? el.outerHtml() else { return [] }
        var tag = ""
        var quote: Character? = nil
        for ch in html {
            if let q = quote {
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                break
            }
            tag.append(ch)
        }
        guard let re = regex(#"([A-Za-z_:][A-Za-z0-9_:.\-]*)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'/>]+)))?"#) else { return [] }
        let matches = re.matches(in: tag, range: NSRange(tag.startIndex..., in: tag))
        var out: [(name: String, value: String)] = []
        for (i, m) in matches.enumerated() {
            if i == 0 { continue }   // o primeiro token é o nome da tag
            guard let nr = Range(m.range(at: 1), in: tag) else { continue }
            var value = ""
            for g in 2...4 where m.range(at: g).location != NSNotFound {
                if let vr = Range(m.range(at: g), in: tag) { value = String(tag[vr]); break }
            }
            value = value
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            out.append((String(tag[nr]).lowercased(), value))
        }
        return out
    }

    /// buildSelector do web: tag + TODAS as classes; sem classe, tag#id;
    /// senão a tag pura.
    static func buildSelector(_ el: Element) -> String {
        let tag = el.tagName()
        let cls = classesInOrder(el)
        if !cls.isEmpty { return tag + "." + cls.joined(separator: ".") }
        let id = el.attrOrEmpty("id")
        if !id.isEmpty { return tag + "#" + id }
        return tag
    }

    /// Classe volátil (v1.8 do web): muda com user-agent/estado ou tem
    /// cara de hash — não pode grudar em seletor que vai pro app.
    static func isVolatileClass(_ c: String) -> Bool {
        if c.isEmpty { return true }
        let lc = c.lowercased()
        let exact: Set<String> = ["mobile", "pc", "desktop", "tablet", "phone",
                                  "ios", "android", "active", "open", "opened",
                                  "closed", "selected", "hidden", "current",
                                  "visible", "invisible", "expanded", "collapsed",
                                  "show", "shown", "on"]
        if exact.contains(lc) { return true }
        if lc.hasPrefix("js_") || lc.hasPrefix("js-") { return true }
        if lc.hasPrefix("js"), lc.count > 2 {
            let third = lc[lc.index(lc.startIndex, offsetBy: 2)]
            if third == "_" || third == "-" { return true }
        }
        if lc.hasPrefix("m-") { return true }
        if lc.count >= 8, lc.allSatisfy({ $0.isLetter || $0.isNumber }),
           lc.contains(where: { $0.isNumber }), lc.contains(where: { $0.isLetter }) {
            let vowels = lc.filter { "aeiou".contains($0) }.count
            let isHex = lc.allSatisfy { $0.isNumber || "abcdef".contains($0) }
            if vowels <= 1 || isHex { return true }
        }
        return false
    }

    static func stableClasses(_ el: Element) -> [String] {
        classesInOrder(el).filter { !isVolatileClass($0) }
    }

    /// buildRobustSelector do web: tag + até 2 classes estáveis; sem
    /// elas, tag#id não-volátil; senão a tag pura.
    static func buildRobustSelector(_ el: Element) -> String {
        let tag = el.tagName()
        let st = stableClasses(el)
        if !st.isEmpty { return tag + "." + st.prefix(2).joined(separator: ".") }
        let id = el.attrOrEmpty("id")
        if !id.isEmpty && !isVolatileClass(id) { return tag + "#" + id }
        return tag
    }

    /// selForEl do web: com alguma classe volátil, usa o robusto.
    static func selForEl(_ el: Element) -> String {
        classesInOrder(el).contains(where: isVolatileClass)
            ? buildRobustSelector(el) : buildSelector(el)
    }

    /// uniqueRelSelector do web: a forma mais curta que casa
    /// EXATAMENTE o alvo dentro da raiz (tag → tag.classe → tag.todas →
    /// #id → últimos 2 elos da cadeia → cadeia inteira); sem forma
    /// única, devolve a cadeia inteira (ou a tag).
    static func uniqueRelSelector(root: Element, target: Element) -> String? {
        if target === root { return "this" }
        func matches(_ sel: String) -> Bool {
            let found = select(root, sel)
            return found.count == 1 && found.first === target
        }
        let tag = target.tagName()
        let cls = classesInOrder(target)
        var opts: [String] = [tag]
        if let c0 = cls.first { opts.append(tag + "." + c0) }
        if cls.count > 1 { opts.append(tag + "." + cls.joined(separator: ".")) }
        let id = target.attrOrEmpty("id")
        if !id.isEmpty { opts.append("#" + id) }
        var chain: [String] = []
        var cur: Element? = target
        while let c = cur, c !== root {
            chain.insert(buildSelector(c), at: 0)
            cur = c.parent()
        }
        if chain.count > 1 { opts.append(chain.suffix(2).joined(separator: " ")) }
        if !chain.isEmpty { opts.append(chain.joined(separator: " ")) }
        for o in opts where matches(o) { return o }
        return chain.isEmpty ? tag : chain.joined(separator: " ")
    }

    /// sanitizeSelector320 do web (v3.20): tokens de id/classe com
    /// espaço, float ou cara de hash/placeholder saem do seletor
    /// emitido. Seletores com atributo/pseudo ([, (, {) não são tocados.
    static func sanitizeSelector(_ sel: String) -> String {
        let t = sel.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t == "this" { return sel }
        if t.contains("[") || t.contains("(") || t.contains("{") { return sel }
        func hashLike(_ tok: String) -> Bool {
            guard tok.count >= 8,
                  tok.allSatisfy({ $0.isLetter || $0.isNumber }),
                  tok.contains(where: { $0.isNumber }) else { return false }
            let low = tok.lowercased()
            if low.allSatisfy({ $0.isNumber || "abcdef".contains($0) }) { return true }
            return low.filter { "aeiou".contains($0) }.count <= 1
        }
        func identOk(_ tok: String) -> Bool {
            guard let re = regex("^-?[_a-zA-Z][_a-zA-Z0-9-]*$"),
                  re.firstMatch(in: tok, range: NSRange(tok.startIndex..., in: tok)) != nil
            else { return false }
            return !hashLike(tok)
        }
        func cleanSeg(_ seg: String) -> String {
            guard let re = regex(#"^(\*|[a-zA-Z][a-zA-Z0-9-]*)?((?:[#.][^#.]+)*)$"#),
                  let m = re.firstMatch(in: seg, range: NSRange(seg.startIndex..., in: seg))
            else { return "" }
            let tag = Range(m.range(at: 1), in: seg).map { String(seg[$0]) } ?? ""
            let rest = Range(m.range(at: 2), in: seg).map { String(seg[$0]) } ?? ""
            var toks: [String] = []
            if let tre = regex("([#.])([^#.]+)") {
                for tm in tre.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) {
                    guard let r1 = Range(tm.range(at: 1), in: rest),
                          let r2 = Range(tm.range(at: 2), in: rest) else { continue }
                    let name = String(rest[r2])
                    if identOk(name) { toks.append(String(rest[r1]) + name) }
                }
            }
            if tag.isEmpty && toks.isEmpty { return "" }
            return tag + toks.joined()
        }
        var clean = ""
        if let segRe = regex(#"[^\s>+~]+"#) {
            var last = t.startIndex
            for m in segRe.matches(in: t, range: NSRange(t.startIndex..., in: t)) {
                guard let r = Range(m.range, in: t) else { continue }
                clean += t[last..<r.lowerBound]
                clean += cleanSeg(String(t[r]))
                last = r.upperBound
            }
            clean += t[last...]
        } else {
            clean = t
        }
        clean = clean.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init).joined(separator: " ")
        while clean.contains(" >  > ") { clean = clean.replacingOccurrences(of: " >  > ", with: " > ") }
        if clean.hasPrefix("> ") { clean = String(clean.dropFirst(2)) }
        if clean.hasSuffix(" >") { clean = String(clean.dropLast(2)) }
        clean = clean.trimmingCharacters(in: .whitespaces)
        if clean.isEmpty {
            let firstToken = t.split(whereSeparator: { $0 == " " }).first.map(String.init) ?? ""
            if let tre = regex("^[a-zA-Z][a-zA-Z0-9-]*"),
               let m = tre.firstMatch(in: firstToken, range: NSRange(firstToken.startIndex..., in: firstToken)),
               let r = Range(m.range, in: firstToken) {
                clean = String(firstToken[r])
            } else {
                return sel
            }
        }
        return clean != t ? clean : sel
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
