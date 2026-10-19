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

    private func scheduleAI() {
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
            if !s.isComplete {
                // Still typing this one: wait for a pause, and for enough words to judge.
                guard words >= 4 else { continue }
                if idle < Self.idleDelay { waitingForIdle = true; continue }
            }
            let before = i > 0 ? sentences[i - 1].text : ""
            let distance = caret < s.range.location ? s.range.location - caret : max(0, caret - s.range.end)
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

    private func recompose() {
        guard let snap = snapshot else { return }
        let local = localText == snap.text ? localIssues : []
        var shown: [Int: AIReview] = [:]
        issues = IssueComposer.compose(text: snap.text, caret: snap.caret, local: local, review: { s in
            let review: AIReview?
            if let edits = self.aiCache[s.text] {
                review = AIReview(text: s.text, edits: edits, complete: true)
            } else if let edits = self.aiPartial[s.text] {
                review = AIReview(text: s.text, edits: edits, complete: false)
            } else {
                review = self.lastReviewAt[s.range.location]  // older version of this sentence
            }
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

    func ignore(_ issue: Issue) {
        ignored.insert(IssueComposer.ignoreKey(issue))
        recompose()
    }

    func learn(_ issue: Issue) {
        local.learn(issue.original)
        localIssues.removeAll { $0.original == issue.original && $0.kind == .spelling }
        ignored.insert(IssueComposer.ignoreKey(issue))
        recompose()
    }
}
