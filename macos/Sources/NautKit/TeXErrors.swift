import Foundation

/// What libnaut found wrong in TeX. It draws a mistake in place, as an
/// `<merror>` around the offending text, rather than refusing the
/// formula; this turns those back into words for the equation editor.
public enum TeXErrors {
    /// One message per mistake, in order: an unknown `\command` or a
    /// stray character.
    public static func messages(_ tex: String) -> [String] {
        messages(inHTML: Markdown.render("$$\n\(tex)\n$$").html)
    }

    static func messages(inHTML html: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: "<merror><mtext>(.*?)</mtext></merror>")
        let ns = html as NSString
        return pattern.matches(in: html, range: NSRange(location: 0, length: ns.length)).map { m in
            let text = ns.substring(with: m.range(at: 1))
                .replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
                .replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&amp;", with: "&")
            return text.hasPrefix("\\") ? "Undefined control sequence: \(text)" : "Unexpected “\(text)”"
        }
    }
}
