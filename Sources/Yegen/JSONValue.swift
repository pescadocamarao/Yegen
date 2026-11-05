import Foundation

/// JSON com ORDEM DE CHAVES PRESERVADA — a rule do Yealico sai sempre na
/// mesma ordem da versão web (name, version, isEditable, isEncrypted,
/// domain, …). Um Dictionary do Swift não garante ordem, por isso o motor
/// monta a rule com este tipo e serializa com indentação de 2 espaços.
enum JVal {
    case str(String)
    case bool(Bool)
    case int(Int)
    case obj([(String, JVal)])
    case arr([JVal])

    func serialized(indent: Int = 0) -> String {
        let pad = String(repeating: " ", count: indent)
        let padIn = String(repeating: " ", count: indent + 2)
        switch self {
        case .str(let s):
            return JVal.escape(s)
        case .bool(let b):
            return b ? "true" : "false"
        case .int(let n):
            return String(n)
        case .arr(let items):
            if items.isEmpty { return "[]" }
            let inner = items.map { padIn + $0.serialized(indent: indent + 2) }
                .joined(separator: ",\n")
            return "[\n\(inner)\n\(pad)]"
        case .obj(let pairs):
            if pairs.isEmpty { return "{}" }
            let inner = pairs.map {
                padIn + JVal.escape($0.0) + ": " + $0.1.serialized(indent: indent + 2)
            }.joined(separator: ",\n")
            return "{\n\(inner)\n\(pad)}"
        }
    }

    static func escape(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
