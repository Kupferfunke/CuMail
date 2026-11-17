import Foundation

/// A deliberately inert subset of email CSS. No URLs, imports, custom properties,
/// escapes, generated content, scripts or animation enter the rendered document.
enum MailCSS {
    private static let properties: Set<String> = [
        "color", "background", "background-color", "background-image", "background-size", "background-position", "background-repeat",
        "font", "font-family", "font-size", "font-weight", "font-style", "font-variant", "line-height", "letter-spacing", "word-spacing",
        "text-align", "text-align-last", "text-decoration", "text-decoration-color", "text-transform", "text-indent", "text-size-adjust", "-webkit-text-size-adjust",
        "white-space", "word-break", "overflow-wrap", "word-wrap", "vertical-align", "direction", "unicode-bidi",
        "width", "min-width", "max-width", "height", "min-height", "max-height", "box-sizing", "aspect-ratio",
        "margin", "margin-top", "margin-right", "margin-bottom", "margin-left", "margin-inline", "margin-inline-start", "margin-inline-end",
        "padding", "padding-top", "padding-right", "padding-bottom", "padding-left", "padding-inline", "padding-block",
        "border", "border-top", "border-right", "border-bottom", "border-left", "border-color", "border-style", "border-width",
        "border-top-color", "border-right-color", "border-bottom-color", "border-left-color", "border-top-width", "border-right-width", "border-bottom-width", "border-left-width",
        "border-radius", "border-top-left-radius", "border-top-right-radius", "border-bottom-left-radius", "border-bottom-right-radius",
        "border-collapse", "border-spacing", "table-layout", "empty-cells", "caption-side",
        "display", "visibility", "opacity", "overflow", "overflow-x", "overflow-y", "float", "clear",
        "list-style-type", "list-style-position", "object-fit", "object-position", "box-shadow", "text-shadow",
        "flex", "flex-grow", "flex-shrink", "flex-basis", "flex-direction", "flex-wrap", "align-items", "align-self", "align-content",
        "justify-content", "order", "gap", "row-gap", "column-gap", "grid-template-columns", "grid-template-rows", "grid-column", "grid-row"
    ]
    private static let functions: Set<String> = ["rgb", "rgba", "hsl", "hsla", "hwb", "lab", "lch", "oklab", "oklch", "color", "color-mix",
        "calc", "min", "max", "clamp", "linear-gradient", "radial-gradient", "repeating-linear-gradient", "repeat", "minmax", "fit-content"]

    static func declarations(_ raw: String) -> String {
        guard raw.utf8.count <= 32 * 1024, let source = uncomment(raw) else { return "" }
        return split(source, at: ";").prefix(160).compactMap { declaration in
            guard let colon = declaration.firstIndex(of: ":") else { return nil }
            let name = declaration[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = declaration[declaration.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard properties.contains(name), !value.isEmpty, value.utf8.count <= 2048,
                  value.range(of: "^[A-Za-z0-9 \\t\\r\\n#.,%'\"!()+*/_-]+$", options: .regularExpression) != nil,
                  balanced(value), safeFunctions(value) else { return nil }
            return name + ":" + value
        }.joined(separator: ";")
    }

    static func stylesheet(_ raw: String) -> String {
        guard raw.utf8.count <= 256 * 1024, let source = uncomment(raw) else { return "" }
        return rules(source, depth: 0, scope: nil)
    }

    static func quotedStylesheet(_ raw: String, scope: String) -> String {
        rules(raw, depth: 0, scope: scope)
    }

    private static func rules(_ source: String, depth: Int, scope: String?) -> String {
        guard depth < 5 else { return "" }
        var header = "", body = "", output = "", nesting = 0, quote: Character?
        for char in source {
            if let current = quote {
                if nesting == 0 { header.append(char) } else { body.append(char) }
                if char == current { quote = nil }
                continue
            }
            if char == "\"" || char == "'" {
                quote = char
                if nesting == 0 { header.append(char) } else { body.append(char) }
            } else if char == "{" {
                if nesting > 0 { body.append(char) }; nesting += 1
            } else if char == "}" {
                guard nesting > 0 else { return output }
                nesting -= 1
                if nesting > 0 { body.append(char); continue }
                let selector = header.trimmingCharacters(in: .whitespacesAndNewlines)
                if selector.lowercased().hasPrefix("@media ") {
                    let query = String(selector.dropFirst(7))
                    // Match viewport rules, not OS colour-scheme rewrites of the sender's colours.
                    if query.utf8.count < 1024, query.range(of: "^[A-Za-z0-9 .,:()_-]+$", options: .regularExpression) != nil,
                       !query.lowercased().contains("prefers-color-scheme") {
                        let nested = rules(body, depth: depth + 1, scope: scope)
                        if !nested.isEmpty { output += "@media " + query + "{" + nested + "}" }
                    }
                } else if selector.utf8.count <= 4096,
                          selector.range(of: "^[A-Za-z0-9_#. \\t\\r\\n,:>+~*\\[\\]=|^$'\"()!-]+$", options: .regularExpression) != nil,
                          !selector.contains("@"), balanced(selector) {
                    let safe = declarations(body)
                    if !safe.isEmpty {
                        let scoped = scope.map { scope in split(selector, at: ",").map { scope + " " + quotedSelector($0) }.joined(separator: ",") } ?? selector
                        output += scoped + "{" + safe + "}"
                    }
                }
                header = ""; body = ""
            } else if nesting == 0 && char == ";" { header = "" } // @import / @charset
            else if nesting == 0 { header.append(char) }
            else { body.append(char) }
        }
        return output
    }

    /// The received document's roots become elements inside the quotation.
    /// Attribute values and strings must not be rewritten (e.g. [title="body"]).
    private static func quotedSelector(_ raw: String) -> String {
        let chars = Array(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        var result = "", index = 0, brackets = 0, quote: Character?
        while index < chars.count {
            let char = chars[index]
            if let current = quote {
                result.append(char); if char == current { quote = nil }; index += 1; continue
            }
            if char == "\"" || char == "'" { quote = char; result.append(char); index += 1; continue }
            if char == "[" { brackets += 1 }
            if char == "]" { brackets -= 1 }
            let boundary = index == 0 || " \t\r\n>+~,(".contains(chars[index - 1])
            if brackets == 0, boundary {
                var replaced = false
                for (token, replacement) in [(":root", ".cumail-original-html"), ("html", ".cumail-original-html"), ("body", ".cumail-original-body")] {
                    let end = index + token.count
                    guard end <= chars.count, String(chars[index..<end]).lowercased() == token,
                          end == chars.count || !(chars[end].isLetter || chars[end].isNumber || chars[end] == "-" || chars[end] == "_") else { continue }
                    result += replacement; index = end; replaced = true; break
                }
                if replaced { continue }
            }
            result.append(char); index += 1
        }
        return result
    }

    private static func safeFunctions(_ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "([A-Za-z_-][A-Za-z0-9_-]*)\\s*\\(") else { return false }
        let ns = value as NSString
        return regex.matches(in: value, range: NSRange(location: 0, length: ns.length)).allSatisfy {
            functions.contains(ns.substring(with: $0.range(at: 1)).lowercased())
        }
    }
    private static func balanced(_ text: String) -> Bool {
        var quote: Character?, nesting = 0
        for char in text {
            if let current = quote { if char == current { quote = nil }; continue }
            if char == "'" || char == "\"" { quote = char }
            else if char == "(" { nesting += 1; if nesting > 12 { return false } }
            else if char == ")" { nesting -= 1; if nesting < 0 { return false } }
        }
        return quote == nil && nesting == 0
    }
    private static func split(_ text: String, at delimiter: Character) -> [String] {
        var quote: Character?, nesting = 0, current = "", result: [String] = []
        for char in text {
            if let existing = quote { if char == existing { quote = nil } }
            else if char == "'" || char == "\"" { quote = char }
            else if char == "(" { nesting += 1 }
            else if char == ")" { nesting -= 1 }
            else if char == delimiter && nesting == 0 { result.append(current); current = ""; continue }
            current.append(char)
        }
        result.append(current); return result
    }
    private static func uncomment(_ raw: String) -> String? {
        // Escapes can disguise tokens such as url/expression. Fail closed instead of decoding CSS.
        guard !raw.contains("\\"), !raw.contains("<") else { return nil }
        return stripComments(raw)
    }
    private static func stripComments(_ raw: String) -> String {
        var result = "", quote: Character?, index = raw.startIndex
        while index < raw.endIndex {
            let char = raw[index], next = raw.index(after: index)
            if let current = quote { if char == current { quote = nil }; result.append(char); index = next; continue }
            if char == "'" || char == "\"" { quote = char }
            if char == "/", next < raw.endIndex, raw[next] == "*" {
                guard let end = raw.range(of: "*/", range: raw.index(after: next)..<raw.endIndex) else { break }
                index = end.upperBound; continue
            }
            result.append(char); index = next
        }
        return result
    }
}
