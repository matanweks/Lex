import AppKit
import LexCore

/// Runs the checking pipeline for whatever field has focus:
/// macOS spell/grammar on every keystroke (instant), Claude per sentence the moment
/// you finish it, results cached by sentence text so edits elsewhere never re-check it.
final class Engine {
    static let idleDelay: TimeInterval = 0.7
    static let maxConcurrent = 4

    let tracker = FocusTracker()
    let overlay = OverlayController()
    let settings: AppSettings
    let client: ClaudeClient
    private let local = LocalChecker()

    private(set) var snapshot: FieldSnapshot?
    private(set) var issues: [Issue] = []
    /// The app the user was last typing in (for "Turn off in …").
    private(set) var lastTargetApp: (bundleID: String, name: String)?
    private(set) var lastError: String?
    var onStatusChange: (() -> Void)?

    private var localIssues: [Issue] = []
    private var localText = ""
    private var localWork: DispatchWorkItem?
    private var aiCache: [String: [AIEdit]] = [:]
    /// Edits streamed so far for checks still in flight.
    private var aiPartial: [String: [AIEdit]] = [:]
    /// The last review shown at each sentence start, reused while that sentence is edited.
    private var lastReviewAt: [Int: AIReview] = [:]
    private var aiInFlight = Set<String>()
    private var aiFailures: [String: Date] = [:]
    private var lastTextChange = Date.distantPast
    private var idleTimer: Timer?
    private var ignored = Set<String>()
    /// Names Claude accepted, with the sentences it accepted them in; learned after two.
    private var nameVotes: [String: Set<String>] = [:]
    /// Sentences you were typing (not text that was already in the field), for your voice profile.
    private var authored = Set<String>()
    private var lastExpansion: (location: Int, at: Date)?
    private var rectGeneration = 0
    private var lastOverlaySummary = ""
    private var started = false
    private var paused = false

    init(settings: AppSettings, client: ClaudeClient) {
        self.settings = settings
        self.client = client
        overlay.onApply = { [weak self] issue, replacement in self?.apply(issue, replacement: replacement) }
        overlay.onIgnore = { [weak self] issue in self?.ignore(issue) }
        overlay.onLearn = { [weak self] issue in self?.learn(issue) }
    }

    func start() {
        guard !started else { return }
        started = true
        tracker.onUpdate = { [weak self] update in self?.handle(update) }
        tracker.setExcluded(settings.excludedApps)
        tracker.setPaused(!settings.enabled)
        tracker.start()
        Log.info("engine started")
    }

    var isChecking: Bool { !aiInFlight.isEmpty }

    /// While the refine panel is up, or when the user pauses Lex.
    func setPaused(_ paused: Bool) {
        self.paused = paused
        tracker.setPaused(paused || !settings.enabled)
        if paused || !settings.enabled {
            snapshot = nil
            overlay.clear()
        }
    }

    func settingsChanged() {
        tracker.setExcluded(settings.excludedApps)
        tracker.setPaused(paused || !settings.enabled)
        if !settings.enabled { snapshot = nil; overlay.clear() }
        recompose()
        scheduleAI()
    }

    // MARK: Pipeline

    private func handle(_ u: TrackerUpdate) {
        guard let snap = u.snapshot else {
            snapshot = nil
            issues = []
            overlay.clear()
            return
        }
        if u.elementChanged {
            lastReviewAt = [:]
            localIssues = []
            localText = ""
            issues = []
            overlay.clear()
            client.warmUpIfCold()
            let name = NSRunningApplication(processIdentifier: snap.pid)?.localizedName ?? snap.bundleID
            lastTargetApp = (snap.bundleID, name)
            Log.info("focus: \(snap.bundleID) web=\(snap.webBased) chars=\((snap.text as NSString).length)")
        }
        let previous = snapshot
        snapshot = snap
        if u.textChanged {
            lastTextChange = Date()
            if previous != nil, !u.elementChanged, !localText.isEmpty {
                localIssues = IssueComposer.shift(localIssues, from: localText, to: snap.text)
                localText = snap.text
            }
            overlay.hideCard()
            if !u.elementChanged { expandSnippet(in: snap) }
            runLocalCheck()
            scheduleAI()
        }
        if u.textChanged || u.selectionChanged {
            recompose()
        } else if u.geometryChanged {
            refreshRects()
        }
    }

    private func runLocalCheck() {
        localWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let text = self.snapshot?.text else { return }
            self.local.check(text) { [weak self] found in
                guard let self, let current = self.snapshot?.text else { return }
                self.localIssues = current == text ? found : IssueComposer.shift(found, from: text, to: current)
                self.localText = current
                self.recompose()
            }
        }
        localWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func scheduleAI(force: Bool = false) {
        idleTimer?.invalidate()
        guard let snap = snapshot, settings.enabled, let model = settings.liveModel, client.hasKey else {
            onStatusChange?()
            return
        }
        let sentences = SentenceSplitter.split(snap.text, caret: snap.caret)
        let idle = Date().timeIntervalSince(lastTextChange)
        let caret = snap.selection.location
        var candidates: [(sentence: Sentence, before: String, distance: Int)] = []
        var waitingForIdle = false
        for (i, s) in sentences.enumerated() {
            let words = s.text.split(whereSeparator: \.isWhitespace).count
            guard words >= 2, aiCache[s.text] == nil, !aiInFlight.contains(s.text) else { continue }
            if let failedAt = aiFailures[s.text], Date().timeIntervalSince(failedAt) < 30 { continue }
            if !s.isComplete, !force {
                // Still typing this one: wait for a pause, and for enough words to judge.
                guard words >= 4 else { continue }
                if idle < Self.idleDelay { waitingForIdle = true; continue }
            }
            let before = i > 0 ? sentences[i - 1].text : ""
            let distance = caret < s.range.location ? s.range.location - caret : max(0, caret - s.range.end)
            if distance <= 2, idle < 5 {
                if authored.count > 200 { authored.removeAll() }
                authored.insert(s.text)
            }
            candidates.append((s, before, distance))
        }
        if waitingForIdle {
            idleTimer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay - idle + 0.02, repeats: false) { [weak self] _ in self?.scheduleAI() }
        }
        // Closest to the caret first: that's the sentence you just finished.
        for c in candidates.sorted(by: { $0.distance < $1.distance }) where aiInFlight.count < Self.maxConcurrent {
            launch(c.sentence, before: c.before, model: model)
        }
        updateBadgeOnly()
        onStatusChange?()
    }

    private func launch(_ sentence: Sentence, before: String, model: ClaudeModel) {
        let key = sentence.text
        aiInFlight.insert(key)
        let started = Date()
        let client = self.client
        Task {
            do {
                var firstEditMs: Int?
                let edits = try await client.check(sentence: key, before: before, finished: sentence.isComplete, model: model) { edit in
                    if firstEditMs == nil { firstEditMs = Int(Date().timeIntervalSince(started) * 1000) }
                    DispatchQueue.main.async { self.partial(key, edit) }
                }
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                await MainActor.run { self.finish(key, edits: edits, ms: ms, firstEditMs: firstEditMs) }
            } catch {
                await MainActor.run { self.fail(key, error: error) }
            }
        }
    }

    private func partial(_ key: String, _ edit: AIEdit) {
        guard aiInFlight.contains(key) else { return }
        aiPartial[key, default: []].append(edit)
        if snapshot?.text.contains(key) == true { recompose() }
    }

    private func finish(_ key: String, edits: [AIEdit], ms: Int, firstEditMs: Int?) {
        aiInFlight.remove(key)
        aiPartial[key] = nil
        if aiCache.count > 5000 { aiCache.removeAll() }
        aiCache[key] = edits
        lastError = nil
        Log.info("AI check \(key.split(separator: " ").count) words: \(ms) ms, \(edits.count) edits" + (firstEditMs.map { ", first at \($0) ms" } ?? ""))
        noteNames(in: key, edits: edits)
        if authored.remove(key) != nil, edits.isEmpty, key.split(whereSeparator: \.isWhitespace).count >= 6 {
            settings.addVoiceSample(key)
        }
        if snapshot?.text.contains(key) == true { recompose() }
        scheduleAI()
    }

    private func fail(_ key: String, error: Error) {
        aiInFlight.remove(key)
        aiPartial[key] = nil
        aiFailures[key] = Date()
        lastError = error.localizedDescription
        Log.info("AI check failed: \(error.localizedDescription)")
        updateBadgeOnly()
        onStatusChange?()
    }

    /// Claude's verdict on a sentence: finished, still streaming, or for an older version.
    private func review(for s: Sentence) -> AIReview? {
        if let edits = aiCache[s.text] { return AIReview(text: s.text, edits: edits, complete: true) }
        if let edits = aiPartial[s.text] { return AIReview(text: s.text, edits: edits, complete: false) }
        return lastReviewAt[s.range.location]  // older version of this sentence
    }

    private func recompose() {
        guard let snap = snapshot else { return }
        let local = localText == snap.text ? localIssues : []
        var shown: [Int: AIReview] = [:]
        issues = IssueComposer.compose(text: snap.text, caret: snap.caret, local: local, review: { s in
            let review = self.review(for: s)
            if let review { shown[s.range.location] = review }
            return review
        }, ignored: ignored)
        lastReviewAt = shown
        tracker.setProbe(issues.first.map { NSRange(location: $0.range.location, length: min($0.range.length, 1)) })
        refreshRects()
    }

    private func refreshRects() {
        guard let snap = snapshot, !paused else { return }
        rectGeneration += 1
        let generation = rectGeneration
        let current = issues
        tracker.rects(for: current, in: snap) { [weak self] rects in
            guard let self, generation == self.rectGeneration, !self.paused, self.snapshot != nil else { return }
            let summary = "\(current.count) issues (\(current.filter { $0.source == .ai }.count) from Claude), \(rects.count) drawn"
            if summary != self.lastOverlaySummary {
                self.lastOverlaySummary = summary
                Log.info("overlay: \(summary)")
            }
            self.overlay.show(issues: current, rects: rects, field: snap, badge: self.badgeState, showBadge: self.settings.showBadge)
        }
    }

    private var badgeState: (count: Int, checking: Bool, aiOn: Bool) {
        (issues.count, !aiInFlight.isEmpty, settings.liveModel != nil && client.hasKey && lastError == nil)
    }

    private func updateBadgeOnly() {
        guard !paused else { return }
        overlay.updateBadge(badgeState, field: snapshot, visible: settings.showBadge)
    }

    // MARK: Actions

    func apply(_ issue: Issue, replacement: String) {
        guard let snap = snapshot else { return }
        issues.removeAll { $0.id == issue.id }
        localIssues.removeAll { $0.range.intersects(issue.range) }
        refreshRects()
        tracker.replace(in: snap, range: issue.range, original: issue.original, with: replacement) { outcome in
            if outcome == .failed {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(replacement, forType: .string)
                Toast.show("This field didn't take the edit. The fix is on your clipboard.")
            }
        }
    }

    /// Applies every correction in the focused field at once. Asks Claude to check any
    /// sentence it hasn't seen (including the one you're typing) and waits up to 2.5 s for
    /// those checks, so a name only the spell checker flagged isn't "fixed".
    func fixAll() {
        guard snapshot != nil else {
            Toast.show("Click into a text field with mistakes first.")
            return
        }
        overlay.hideCard()
        scheduleAI(force: true)
        let started = Date()
        func attempt() {
            if !aiInFlight.isEmpty, Date().timeIntervalSince(started) < 2.5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { attempt() }
                return
            }
            guard let snap = snapshot else { return }
            let local = localText == snap.text ? localIssues : []
            // No caret: the word you just finished typing counts too.
            let all = IssueComposer.compose(text: snap.text, caret: nil, local: local, review: { self.review(for: $0) }, ignored: ignored)
            let fixes = IssueComposer.fixes(all)
            guard !fixes.isEmpty else {
                Toast.show(all.isEmpty ? "Nothing to fix." : "Only style suggestions left; hover them to choose.")
                return
            }
            Log.info("fix all: \(fixes.count) fixes after \(Int(Date().timeIntervalSince(started) * 1000)) ms wait")
            issues.removeAll { issue in fixes.contains { $0.id == issue.id } }
            refreshRects()
            tracker.replaceAll(in: snap, fixes: fixes) { applied in
                Toast.show(applied == fixes.count
                           ? "Fixed \(applied) \(applied == 1 ? "mistake" : "mistakes")"
                           : "Fixed \(applied) of \(fixes.count); the rest didn't apply cleanly")
            }
        }
        attempt()
    }

    func ignore(_ issue: Issue) {
        ignored.insert(IssueComposer.ignoreKey(issue))
        recompose()
    }

    func learn(_ issue: Issue) {
        local.learn(issue.original)
        settings.learn(issue.original)
        localIssues.removeAll { $0.original == issue.original && $0.kind == .spelling }
        ignored.insert(IssueComposer.ignoreKey(issue))
        recompose()
    }

    // MARK: Learning and snippets

    /// A name the spell checker keeps flagging but Claude reads as fine, in two different
    /// sentences, is learned: it stops being underlined and dictation spells it right.
    private func noteNames(in key: String, edits: [AIEdit]) {
        guard let snap = snapshot, localText == snap.text else { return }
        let sentence = (snap.text as NSString).range(of: key)
        guard sentence.location != NSNotFound else { return }
        let flagged = localIssues.filter { $0.kind == .spelling && NSIntersectionRange($0.range, sentence).length == $0.range.length }.map(\.original)
        for word in Learning.acceptedNames(flagged: flagged, edits: edits) where !settings.learnedWords.contains(word) {
            nameVotes[word, default: []].insert(key)
            guard nameVotes[word]!.count >= 2 else { continue }
            nameVotes[word] = nil
            local.learn(word)
            settings.learn(word)
            localIssues.removeAll { $0.original == word && $0.kind == .spelling }
            recompose()
        }
    }

    /// A snippet trigger you just typed (";cal" then a space) becomes the snippet's text.
    private func expandSnippet(in snap: FieldSnapshot) {
        guard !settings.snippets.isEmpty, snap.selection.length == 0,
              let (range, snippet) = Snippets.typedExpansion(in: snap.text, caret: snap.selection.location, snippets: settings.snippets) else { return }
        if let last = lastExpansion, last.location == range.location, Date().timeIntervalSince(last.at) < 1 { return }
        lastExpansion = (range.location, Date())
        // Replace the trigger and the delimiter after it, so the caret lands after both.
        let typed = NSRange(location: range.location, length: range.length + 1)
        let ns = snap.text as NSString
        let original = ns.substring(with: typed)
        let delimiter = ns.substring(with: NSRange(location: typed.end - 1, length: 1))
        tracker.replace(in: snap, range: typed, original: original, with: snippet.text + delimiter) { outcome in
            Log.info("snippet expanded: \(outcome == .failed ? "failed" : "ok")")
        }
    }
}
