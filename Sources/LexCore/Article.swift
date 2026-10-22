import Foundation

/// An article to read: a web page's text (as Safari's Reader would show it) or a post or
/// Article on X.
public struct Article: Codable, Equatable, Sendable, Identifiable {
    public var url: String
    public var title: String
    /// Who wrote it ("By Dana Levi", "@dana").
    public var byline: String
    /// Where it's from ("The Atlantic", "X").
    public var site: String
    /// Paragraphs separated by blank lines.
    public var text: String

    public init(url: String, title: String, byline: String = "", site: String = "", text: String) {
        self.url = url
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.byline = byline.trimmingCharacters(in: .whitespacesAndNewlines)
        self.site = site.trimmingCharacters(in: .whitespacesAndNewlines)
        self.text = Self.tidy(text)
    }

    /// From the page script's result (the share sheet in Safari, or the app's page loader).
    public init?(extracted: [String: Any]) {
        guard let text = extracted["text"] as? String else { return nil }
        let url = extracted["url"] as? String ?? ""
        let site = (extracted["site"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
        self.init(url: url, title: extracted["title"] as? String ?? "", byline: extracted["byline"] as? String ?? "", site: site, text: text)
        guard words >= 20 else { return nil }
    }

    public var id: String { url.isEmpty ? title : url }
    public var words: Int { text.split(whereSeparator: \.isWhitespace).count }
    /// Reading time at a usual pace.
    public var minutes: Int { max(1, Int((Double(words) / 230).rounded())) }
    public var isHebrew: Bool { SpeechText.language(of: String(text.prefix(2000))) == "he" }
    public var paragraphs: [String] { text.components(separatedBy: "\n\n") }

    /// One paragraph per line pair, no runs of spaces or blank lines.
    static func tidy(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}

public enum ArticleLink {
    /// The link in shared text, when the text is about the link: the link alone, or a few
    /// words with it ("Look at this https://…"). Nil for text that merely mentions one.
    public static func find(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        let links = detector.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)).compactMap(\.url)
            .filter { ["http", "https"].contains($0.scheme?.lowercased() ?? "") }
        guard links.count == 1, let link = links.first else { return nil }
        let rest = trimmed.replacingOccurrences(of: link.absoluteString, with: "")
        return rest.split(whereSeparator: \.isWhitespace).count <= 25 ? link : nil
    }

    /// The post's ID in a link to a post on X (or Twitter, and the sites that mirror it).
    public static func xPostID(_ url: URL) -> String? {
        let hosts = ["x.com", "twitter.com", "mobile.twitter.com", "mobile.x.com", "fxtwitter.com", "fixupx.com", "vxtwitter.com", "fixvx.com", "nitter.net"]
        guard let host = url.host?.lowercased().replacingOccurrences(of: "www.", with: ""), hosts.contains(host) else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(where: { $0 == "status" || $0 == "statuses" }), i + 1 < parts.count else { return nil }
        let id = parts[i + 1]
        return !id.isEmpty && id.allSatisfy(\.isNumber) ? id : nil
    }
}

/// Posts and Articles on X, read through FxTwitter (fxtwitter.com, a free open-source service
/// that shows X without logging in), since X shows little to a logged-out reader.
public enum FxTwitter {
    public static func url(for id: String) -> URL { URL(string: "https://api.fxtwitter.com/status/\(id)")! }

    public static func article(from data: Data, url: URL) -> Article? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tweet = json["tweet"] as? [String: Any] else { return nil }
        let author = tweet["author"] as? [String: Any] ?? [:]
        let name = author["name"] as? String ?? ""
        let handle = (author["screen_name"] as? String).map { "@" + $0 } ?? ""
        if let article = tweet["article"] as? [String: Any],
           let blocks = (article["content"] as? [String: Any])?["blocks"] as? [[String: Any]] {
            var numbered = 0
            let paragraphs: [String] = blocks.compactMap { block in
                let text = (block["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let type = block["type"] as? String ?? ""
                guard !text.isEmpty, type != "atomic" else { return nil }
                if type == "ordered-list-item" { numbered += 1; return "\(numbered). \(text)" }
                numbered = 0
                return type == "unordered-list-item" ? "• \(text)" : text
            }
            let result = Article(url: url.absoluteString, title: article["title"] as? String ?? "", byline: [name, handle].filter { !$0.isEmpty }.joined(separator: " "),
                                 site: "X", text: paragraphs.joined(separator: "\n\n"))
            if !result.text.isEmpty { return result }
        }
        var text = postText(tweet)
        if let quote = tweet["quote"] as? [String: Any], !postText(quote).isEmpty {
            let quoted = (quote["author"] as? [String: Any])?["name"] as? String ?? "someone"
            text += "\n\nQuoting \(quoted): \(postText(quote))"
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return Article(url: url.absoluteString, title: name.isEmpty ? "Post on X" : "\(name) on X", byline: handle, site: "X", text: text)
    }

    /// A post's text, with its line breaks as paragraphs.
    static func postText(_ tweet: [String: Any]) -> String {
        let raw = (tweet["raw_text"] as? [String: Any])?["text"] as? String
        let text = (tweet["text"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? raw ?? ""
        return text.replacingOccurrences(of: "\n", with: "\n\n")
    }
}

public enum ArticleText {
    /// The text in parts of about `words` words at most, split between paragraphs, so a long
    /// article can be translated part by part.
    public static func chunks(_ text: String, words: Int = 900) -> [String] {
        var chunks: [String] = []
        var current: [String] = []
        var count = 0
        for paragraph in text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
            let n = paragraph.split(whereSeparator: \.isWhitespace).count
            if count > 0, count + n > words {
                chunks.append(current.joined(separator: "\n\n"))
                current = []
                count = 0
            }
            current.append(paragraph)
            count += n
        }
        if !current.isEmpty { chunks.append(current.joined(separator: "\n\n")) }
        return chunks
    }
}

extension RefineAction {
    public static let articleSummary = RefineAction(
        id: "article-summary", label: "Summary",
        instruction: "Summarize this article for someone deciding whether to read it: one or two sentences on its main point, then 3 to 6 short bullet points (starting with \"• \") with the key facts, arguments and conclusions. Write in the same language as the article. No title or preamble.")

    /// Into Hebrew, or into English for Hebrew text: the two languages you read.
    public static func articleTranslation(for text: String) -> RefineAction {
        let to = Translation.target(for: text)
        return RefineAction(id: "article-translate", label: "To \(to)",
                            instruction: "Translate this text into \(to): natural, fluent \(to) a native reader would write, not word for word. Keep every paragraph and its breaks, and keep names, numbers and links. Translate everything; don't summarize or add notes.")
    }
}
