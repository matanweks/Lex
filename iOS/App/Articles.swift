import Combine
import LexCore
import MediaPlayer
import UIKit
import WebKit

/// Loads an article from its link: posts and Articles on X through FxTwitter, any other page
/// in a hidden web view that runs the page script (`ArticleExtract.js`, Firefox's Readability).
@MainActor
final class ArticleLoader: NSObject, WKNavigationDelegate {
    enum Problem: LocalizedError {
        case xPost, noText

        var errorDescription: String? {
            switch self {
            case .xPost: return "Lex couldn't get this post from X. It may be deleted, from a private account, or not a post."
            case .noText: return "Lex couldn't find an article on this page. In Safari, open the article, then share it to Lex."
            }
        }
    }

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Never>?

    func load(_ url: URL) async throws -> Article {
        if let id = ArticleLink.xPostID(url) {
            var request = URLRequest(url: FxTwitter.url(for: id), timeoutInterval: 20)
            request.setValue("Lex (personal reader)", forHTTPHeaderField: "User-Agent")
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let article = FxTwitter.article(from: data, url: url) else { throw Problem.xPost }
            return article
        }
        return try await loadPage(url)
    }

    private func loadPage(_ url: URL) async throws -> Article {
        let config = WKWebViewConfiguration()
        // Nothing kept between pages: no cookies, no history.
        config.websiteDataStore = .nonPersistent()
        config.applicationNameForUserAgent = "Version/26.0 Mobile/15E148 Safari/604.1"
        config.mediaTypesRequiringUserActionForPlayback = .all
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        web.navigationDelegate = self
        webView = web
        defer {
            web.stopLoading()
            webView = nil
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            loaded = done
            web.load(URLRequest(url: url, timeoutInterval: 25))
            // Some pages never quite finish (ads, live updates): read what's there by then.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.finishLoading()
            }
        }
        guard let file = Bundle.main.url(forResource: "ArticleExtract", withExtension: "js"),
              let script = try? String(contentsOf: file, encoding: .utf8) else { throw Problem.noText }
        // Pages that fill in their text with JavaScript, or are slow, get a moment more, then
        // a second try.
        for wait in [1.2, 4.0] {
            try await Task.sleep(for: .seconds(wait))
            if let article = await extract(web, script) { return article }
        }
        throw Problem.noText
    }

    private func extract(_ web: WKWebView, _ script: String) async -> Article? {
        do {
            let page = try await web.evaluateJavaScript(script + "\nLexArticle.extract();") as? [String: Any]
            voiceLog.info("page script: \((page?["text"] as? String)?.count ?? 0) characters")
            return page.flatMap(Article.init(extracted:))
        } catch {
            voiceLog.error("page script failed: \((error as NSError).code)")
            return nil
        }
    }

    private func finishLoading() {
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishLoading() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finishLoading() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // A redirect cancels the first load; the next one finishes.
        if (error as NSError).code != NSURLErrorCancelled { finishLoading() }
    }
}

/// The Read tab: the article you shared or pasted, read aloud (on with the phone locked, with
/// the lock screen's controls), summarized or translated, and what you read lately.
@MainActor
final class ArticleModel: ObservableObject {
    enum State: Equatable {
        case empty
        case loading(URL)
        case ready(Article)
        case failed(String, URL?)
    }

    /// A summary or a translation, made from the article or from the summary.
    struct Result: Equatable {
        enum Kind { case summary, translation }
        var kind: Kind
        var title: String
        var text = ""
        var done = false
        var problem: String?
        /// "1 of 4" while a long article is translated part by part.
        var progress: String?
    }

    @Published private(set) var state = State.empty
    @Published private(set) var result: Result?
    @Published private(set) var recent: [Article] = []
    /// What's being read aloud ("Article", "Summary"), for the player bar and the lock screen.
    @Published private(set) var reading: String?
    let reader = Reader()

    private var loadTask: Task<Void, Never>?
    private var workTask: Task<Void, Never>?
    /// The summary or translation being written; an older one's late words are dropped.
    private var runID = UUID()
    private var watching: Set<AnyCancellable> = []
    private static var recentFile: URL { LocalStore.folder.appendingPathComponent("Articles.json") }

    init() {
        if let data = try? Data(contentsOf: Self.recentFile), let saved = try? JSONDecoder().decode([Article].self, from: data) { recent = saved }
        reader.$phase.sink { [weak self] phase in
            Task { @MainActor in self?.updateLockScreen(phase) }
        }.store(in: &watching)
        let center = MPRemoteCommandCenter.shared()
        for command in [center.togglePlayPauseCommand, center.playCommand, center.pauseCommand] {
            command.addTarget { [weak self] _ in
                MainActor.assumeIsolated { self?.reader.togglePause() }
                return .success
            }
        }
        center.stopCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.stopReading() }
            return .success
        }
    }

    var article: Article? {
        if case .ready(let article) = state { return article }
        return nil
    }

    // MARK: Opening

    func open(_ url: URL) {
        stopWork()
        state = .loading(url)
        loadTask?.cancel()
        // A loader of its own, so a link opened meanwhile doesn't disturb this one.
        let loader = ArticleLoader()
        loadTask = Task {
            do {
                let article = try await loader.load(url)
                guard !Task.isCancelled else { return }
                show(article)
            } catch {
                guard !Task.isCancelled else { return }
                state = .failed(error.localizedDescription, url)
            }
        }
    }

    func show(_ article: Article) {
        stopWork()
        loadTask?.cancel()
        state = .ready(article)
        recent = Array(([article] + recent.filter { $0.id != article.id }).prefix(12))
        try? FileManager.default.createDirectory(at: Self.recentFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(recent).write(to: Self.recentFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Text copied or shared as a link (or the link itself).
    @discardableResult
    func open(text: String) -> Bool {
        guard let url = ArticleLink.find(in: text) else { return false }
        open(url)
        return true
    }

    /// The article the share sheet left for the app, if there is one.
    func takeFromShareSheet() -> Bool {
        guard let item = ArticleInbox.take() else { return false }
        if let article = item.article {
            show(article)
        } else if let url = URL(string: item.url) {
            open(url)
        } else {
            return false
        }
        return true
    }

    func close() {
        stopWork()
        loadTask?.cancel()
        state = .empty
    }

    func forget(_ article: Article) {
        recent.removeAll { $0.id == article.id }
        try? JSONEncoder().encode(recent).write(to: Self.recentFile, options: .atomic)
    }

    // MARK: Claude

    func summarize() {
        guard let article else { return }
        run(Result(kind: .summary, title: "Summary"), parts: [article.text], instruction: RefineAction.articleSummary.instruction)
    }

    /// The whole article, part by part (a long one is too much for one answer).
    func translate() {
        guard let article else { return }
        let action = RefineAction.articleTranslation(for: article.text)
        run(Result(kind: .translation, title: action.label.replacingOccurrences(of: "To ", with: "In ")), parts: ArticleText.chunks(article.text),
            instruction: action.instruction)
    }

    /// The summary in the other language.
    func translateResult() {
        guard let result, result.done, !result.text.isEmpty else { return }
        let action = RefineAction.articleTranslation(for: result.text)
        run(Result(kind: .translation, title: "Summary " + action.label.replacingOccurrences(of: "To ", with: "in ")), parts: [result.text],
            instruction: action.instruction)
    }

    func closeResult() {
        workTask?.cancel()
        runID = UUID()
        if reading != nil, reading != "Article" { stopReading() }
        result = nil
    }

    private func run(_ start: Result, parts: [String], instruction: String) {
        workTask?.cancel()
        if reading != nil, reading != "Article" { stopReading() }
        result = start
        let id = UUID()
        runID = id
        let model = Prefs.current.rewriteModel
        workTask = Task {
            var done = ""
            for (i, part) in parts.enumerated() {
                if parts.count > 1 { result?.progress = "\(i + 1) of \(parts.count)" }
                let before = done.isEmpty ? "" : done + "\n\n"
                do {
                    let text = try await LexEngine.claude.assist(text: part, instruction: instruction, model: model) { partial in
                        Task { @MainActor [weak self] in
                            guard let self, self.runID == id, self.result?.done == false else { return }
                            self.result?.text = before + partial
                        }
                    }
                    guard !Task.isCancelled else { return }
                    done = before + text.trimmingCharacters(in: .whitespacesAndNewlines)
                    result?.text = done
                } catch {
                    guard !Task.isCancelled else { return }
                    result?.problem = error.localizedDescription
                    result?.done = true
                    return
                }
            }
            result?.progress = nil
            result?.done = true
        }
    }

    private func stopWork() {
        workTask?.cancel()
        runID = UUID()
        result = nil
        stopReading()
    }

    // MARK: Reading aloud

    func read(_ text: String, as label: String) {
        if reading == label, reader.isActive {
            reader.togglePause()
            return
        }
        reader.read(text)
        reading = label
    }

    func stopReading() {
        reader.stop()
        reading = nil
    }

    private func updateLockScreen(_ phase: Reader.Phase) {
        guard phase != .idle, let article else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: reading == "Article" || reading == nil ? article.title : "\(reading ?? ""): \(article.title)",
            MPMediaItemPropertyArtist: article.site.isEmpty ? "Lex" : article.site,
            MPNowPlayingInfoPropertyPlaybackRate: phase == .playing ? 1.0 : 0.0,
        ]
    }
}
