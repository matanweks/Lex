import LexCore
import SwiftUI

/// The Read tab: an article to listen to, summarize or translate. Articles arrive from the
/// share sheet (Safari, X, any app) or a pasted link.
struct ArticleView: View {
    @ObservedObject var model: ArticleModel
    @ObservedObject var reader: Reader
    @State private var pasteProblem: String?
    /// Select in the Lately list: articles to mark read or unread, or remove, together.
    @State private var selecting = false
    @State private var selection = Set<String>()

    var body: some View {
        NavigationStack {
            Group {
                switch model.state {
                case .empty: start
                case .loading(let url): loading(url)
                case .failed(let message, let url): failed(message, url)
                case .ready(let article): page(article)
                }
            }
            .navigationTitle(model.article == nil ? "Read" : "")
            .navigationBarTitleDisplayMode(model.article == nil ? .large : .inline)
            .toolbar {
                if model.article != nil {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Articles", systemImage: "chevron.backward") { model.close() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Paste a Link", systemImage: "link.badge.plus", action: pasteLink)
                        .accessibilityIdentifier("article-paste")
                }
            }
        }
        .alert(pasteProblem ?? "", isPresented: Binding(get: { pasteProblem != nil }, set: { if !$0 { pasteProblem = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .safeAreaInset(edge: .bottom) {
            if reader.isActive { player }
        }
    }

    // MARK: No article yet

    private var start: some View {
        List(selection: $selection) {
            if !selecting {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "newspaper").font(.system(size: 34)).foregroundStyle(Brand.indigo)
                        Text("Listen to an article, or get its summary or translation.").font(.headline)
                        Text("In Safari, X or any app, tap Share, then Lex. Or copy a link and paste it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Button(action: pasteLink) {
                            Label("Paste a Link", systemImage: "link.badge.plus")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .frame(height: 36)
                                .background(Capsule().fill(Brand.indigo))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                    .padding(.vertical, 6)
                }
            }
            if !model.recent.isEmpty {
                Section {
                    ForEach(model.recent) { article in
                        let read = model.isRead(article)
                        Group {
                            if selecting {
                                row(article, read: read)
                            } else {
                                Button { model.show(article) } label: { row(article, read: read) }
                                    .foregroundStyle(.primary)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button(read ? "Unread" : "Read", systemImage: read ? "circle" : "checkmark.circle") { model.setRead(article, !read) }
                                .tint(Brand.indigo)
                        }
                        .swipeActions { Button("Remove", role: .destructive) { model.forget(article) } }
                        .contextMenu {
                            Button(read ? "Mark as Unread" : "Mark as Read", systemImage: read ? "circle" : "checkmark.circle") { model.setRead(article, !read) }
                            Button("Remove", systemImage: "trash", role: .destructive) { model.forget(article) }
                        }
                    }
                } header: {
                    HStack {
                        Text(selecting ? (selection.isEmpty ? "Choose articles" : "\(selection.count) selected") : "Lately")
                        Spacer()
                        Button(selecting ? "Done" : "Select") {
                            selecting.toggle()
                            selection = []
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Brand.indigo)
                        .textCase(nil)
                        .accessibilityIdentifier("lately-select")
                    }
                }
            }
        }
        .environment(\.editMode, .constant(selecting ? .active : .inactive))
        .safeAreaInset(edge: .bottom) {
            if selecting { selectionBar }
        }
        .onChange(of: model.recent.isEmpty) { if model.recent.isEmpty { selecting = false } }
    }

    private func row(_ article: Article, read: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: read ? "checkmark.circle.fill" : "circle.fill")
                .font(read ? .callout : .system(size: 8))
                .foregroundStyle(read ? AnyShapeStyle(.secondary) : AnyShapeStyle(Brand.indigo))
                .frame(width: 18)
                .accessibilityLabel(read ? "Read" : "Not read yet")
            VStack(alignment: .leading, spacing: 3) {
                Text(article.title.isEmpty ? article.site : article.title)
                    .font(.callout.weight(read ? .regular : .medium))
                    .foregroundStyle(read ? .secondary : .primary)
                    .lineLimit(2)
                Text([article.site, "\(article.minutes) min"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// What to do with the articles picked in Select.
    private var selectionBar: some View {
        let all = Set(model.recent.map(\.id))
        return HStack(spacing: 18) {
            Button(selection == all ? "None" : "All") { selection = selection == all ? [] : all }
                .accessibilityIdentifier("select-all")
            Spacer()
            Group {
                Button("Read", systemImage: "checkmark.circle") { finishSelection { model.setRead(ids: $0, true) } }
                    .accessibilityIdentifier("select-read")
                Button("Unread", systemImage: "circle") { finishSelection { model.setRead(ids: $0, false) } }
                Button("Remove", systemImage: "trash", role: .destructive) { finishSelection { model.forget(ids: $0) } }
            }
            .disabled(selection.isEmpty)
        }
        .font(.subheadline.weight(.semibold))
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private func finishSelection(_ action: (Set<String>) -> Void) {
        action(selection)
        selection = []
        selecting = false
    }

    /// Opens the link on the clipboard. iOS may ask before Lex reads it (only on this tap).
    private func pasteLink() {
        let board = UIPasteboard.general
        guard board.hasURLs || board.hasStrings else {
            pasteProblem = "Copy a link first, then tap Paste a Link."
            return
        }
        if let url = board.url, ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            model.open(url)
        } else if !(board.string.map { model.open(text: $0) } ?? false) {
            pasteProblem = "There's no link on the clipboard. Copy the article's link, then try again."
        }
    }

    private func loading(_ url: URL) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening the article…").font(.headline)
            Text(url.host ?? url.absoluteString).font(.callout).foregroundStyle(.secondary)
            Button("Cancel") { model.close() }.padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func failed(_ message: String, _ url: URL?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.title).foregroundStyle(.orange)
            Text(message).multilineTextAlignment(.center)
            HStack {
                if let url { Button("Try Again") { model.open(url) }.buttonStyle(.borderedProminent) }
                Button("Back") { model.close() }.buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: The article

    private func page(_ article: Article) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    let source = [article.site, article.byline].filter { !$0.isEmpty }.joined(separator: " · ")
                    if !source.isEmpty { Text(source).font(.footnote.weight(.medium)).foregroundStyle(Brand.indigo) }
                    if !article.title.isEmpty { Text(article.title).font(.title2.bold()) }
                    HStack(spacing: 8) {
                        Text("\(article.words) words · \(article.minutes) min read").font(.caption).foregroundStyle(.secondary)
                        if model.isRead(article) {
                            Label("Read", systemImage: "checkmark.circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Brand.indigo)
                                .accessibilityIdentifier("article-read-badge")
                        }
                    }
                }
                .direction(article.isHebrew)
                actions(article)
                if let result = model.result { resultCard(result) }
                Divider()
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(article.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                        Text(paragraph)
                            .font(.body)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .direction(article.isHebrew)
                .accessibilityIdentifier("article-text")
                // At the end, for when you read it yourself.
                let read = model.isRead(article)
                Button { model.setRead(article, !read) } label: {
                    Label(read ? "Read · Mark as Unread" : "Mark as Read", systemImage: read ? "checkmark.circle.fill" : "checkmark.circle")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .background(Capsule().fill(read ? Color.primary.opacity(0.07) : Brand.indigo))
                        .foregroundStyle(read ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                }
                .buttonStyle(.plain)
                .padding(.top, 10)
                .accessibilityIdentifier("article-mark-read")
            }
            .padding()
        }
    }

    private func actions(_ article: Article) -> some View {
        let target = Translation.target(for: article.text)
        return ScrollView(.horizontal) {
            HStack(spacing: 8) {
                pill(model.reading == "Article" && reader.phase == .playing ? "Pause" : "Read aloud",
                     model.reading == "Article" && reader.phase == .playing ? "pause.fill" : "speaker.wave.2.fill", prominent: true) {
                    model.read(article.text, as: "Article")
                }
                .accessibilityIdentifier("article-read")
                pill("Summary", "text.append") { model.summarize() }
                    .accessibilityIdentifier("article-summary")
                pill("To \(target)", "character.bubble") { model.translate() }
                    .accessibilityIdentifier("article-translate")
                Menu {
                    let read = model.isRead(article)
                    Button(read ? "Mark as Unread" : "Mark as Read", systemImage: read ? "circle" : "checkmark.circle") { model.setRead(article, !read) }
                    Button("Copy the Text", systemImage: "doc.on.doc") { ClipboardLog.copy(article.text) }
                    if let url = URL(string: article.url), url.scheme?.hasPrefix("http") == true {
                        Link(destination: url) { Label("Open the Page", systemImage: "safari") }
                        ShareLink(item: url) { Label("Share the Link", systemImage: "square.and.arrow.up") }
                    }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 38, height: 34).background(Capsule().fill(Color.primary.opacity(0.07)))
                }
            }
        }
        .scrollIndicators(.hidden)
    }

    private func resultCard(_ result: ArticleModel.Result) -> some View {
        let label = result.kind == .summary ? "Summary" : result.title
        let hebrew = SpeechText.language(of: String(result.text.prefix(500))) == "he"
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label(result.title, systemImage: result.kind == .summary ? "text.append" : "character.bubble")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Brand.indigo)
                if !result.done { ProgressView().controlSize(.small) }
                if let progress = result.progress { Text(progress).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { model.closeResult() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .accessibilityLabel("Close")
            }
            if let problem = result.problem { Text(problem).font(.callout).foregroundStyle(.red) }
            Text(result.text.isEmpty ? "Writing…" : result.text)
                .font(.callout)
                .foregroundStyle(result.text.isEmpty ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .direction(hebrew)
                .accessibilityIdentifier("article-result")
            if result.done, !result.text.isEmpty {
                HStack(spacing: 8) {
                    pill(model.reading == label && reader.phase == .playing ? "Pause" : "Read aloud",
                         model.reading == label && reader.phase == .playing ? "pause.fill" : "speaker.wave.2") {
                        model.read(result.text, as: label)
                    }
                    .accessibilityIdentifier("result-read")
                    if result.kind == .summary {
                        pill("In \(Translation.target(for: result.text))", "character.bubble") { model.translateResult() }
                            .accessibilityIdentifier("result-translate")
                    }
                    pill("Copy", "doc.on.doc") { ClipboardLog.copy(result.text) }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Brand.indigo.opacity(0.08)))
    }

    private func pill(_ title: String, _ symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(prominent ? Brand.indigo : Color.primary.opacity(0.07)))
                .foregroundStyle(prominent ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Reading aloud

    private var player: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "waveform").foregroundStyle(Brand.indigo)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.reading == "Article" ? (model.article?.title ?? "Article") : (model.reading ?? "Reading"))
                        .font(.footnote.weight(.semibold))
                        .lineLimit(1)
                    if let note = reader.note {
                        // Why it's the iPhone's voice: no key for the voice picked, or it failed.
                        Text("\(reader.voice) · \(note)").font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Text(reader.phase == .loading ? "Loading…" : reader.voice).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            HStack {
                Menu {
                    Picker("Speed", selection: Binding(get: { reader.speed }, set: { reader.setSpeed($0) })) {
                        ForEach(Reader.speeds, id: \.self) { Text(speedLabel($0)).tag($0) }
                    }
                } label: {
                    Text(speedLabel(reader.speed))
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .frame(minWidth: 52, minHeight: 30)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
                .accessibilityLabel("Speed, \(speedLabel(reader.speed))")
                .accessibilityIdentifier("player-speed")
                Spacer()
                Button { reader.skip(-Reader.skipSeconds) } label: { Image(systemName: "gobackward.15").font(.title2) }
                    .accessibilityLabel("Back 15 seconds")
                    .accessibilityIdentifier("player-back")
                Button { reader.togglePause() } label: {
                    Image(systemName: reader.phase == .paused ? "play.fill" : "pause.fill").font(.title).frame(width: 56)
                }
                .disabled(reader.phase == .loading)
                .accessibilityLabel(reader.phase == .paused ? "Play" : "Pause")
                Button { reader.skip(Reader.skipSeconds) } label: { Image(systemName: "goforward.15").font(.title2) }
                    .accessibilityLabel("Forward 15 seconds")
                    .accessibilityIdentifier("player-forward")
                Spacer()
                Button { model.stopReading() } label: {
                    Image(systemName: "stop.fill").font(.title3).frame(minWidth: 52, minHeight: 30)
                }
                .accessibilityLabel("Stop")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Brand.indigo)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func speedLabel(_ speed: Double) -> String {
        (speed == speed.rounded() ? String(format: "%.0f", speed) : String(format: "%g", speed)) + "×"
    }
}

private extension View {
    /// Hebrew reads right to left.
    func direction(_ hebrew: Bool) -> some View {
        environment(\.layoutDirection, hebrew ? .rightToLeft : .leftToRight)
    }
}
