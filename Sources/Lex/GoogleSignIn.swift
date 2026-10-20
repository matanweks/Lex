import AppKit
import LexCore

/// The gcloud sign-in Lex uses for Google voices and Hebrew dictation. Notices when the
/// organisation's session policy expires it, and runs the browser sign-in again in one click.
final class GoogleSignIn: ObservableObject {
    @Published private(set) var expired = false
    @Published private(set) var signingIn = false

    static let loginCommand = "gcloud auth application-default login"

    /// gcloud has saved a sign-in (it may still have expired).
    var signedIn: Bool { speech.googleSignedIn }

    private let speech: SpeechClient
    private var timer: Timer?

    init(speech: SpeechClient) {
        self.speech = speech
        expired = speech.adc.isExpired
        speech.adc.onExpiredChange = { [weak self] expired in
            DispatchQueue.main.async { self?.update(expired) }
        }
    }

    func start() {
        check()
        // Cheap: Google is only asked when the hour-long access token is due, or after a new sign-in.
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in self?.check() }
    }

    func check() {
        guard speech.googleSignedIn else {
            update(false)
            return
        }
        Task { [speech] in _ = try? await speech.adc.accessToken() }
    }

    /// Test support: shows the expired state without touching the sign-in.
    func preview(_ expired: Bool) { update(expired) }

    private func update(_ value: Bool) {
        guard value != expired else { return }
        expired = value
        Log.info("google sign-in \(value ? "expired" : "works")")
    }

    /// Runs `gcloud auth application-default login`, which opens Google's sign-in in the browser.
    /// Keeps the billing (quota) project from the old sign-in if the new one lacks it.
    func signIn() {
        guard !signingIn else { return }
        guard let gcloud = Self.gcloudPath() else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(Self.loginCommand, forType: .string)
            Toast.show("Couldn't find gcloud. The sign-in command is on your clipboard: paste it in Terminal.")
            return
        }
        let quotaProject = speech.adc.credentials()?.quotaProject
        signingIn = true
        Toast.show("Finish signing in to Google in your browser.")
        let process = Self.process(gcloud, ["auth", "application-default", "login"])
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] p in
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = p.terminationStatus == 0
            if ok, let quotaProject, self?.speech.adc.credentials()?.quotaProject == nil {
                let set = Self.process(gcloud, ["auth", "application-default", "set-quota-project", quotaProject])
                try? set.run()
                set.waitUntilExit()
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.signingIn = false
                Log.info("google sign-in: gcloud exited \(p.terminationStatus)")
                if ok {
                    Task { [speech = self.speech] in
                        let works = (try? await speech.adc.accessToken()) != nil
                        await MainActor.run {
                            Toast.show(works ? "Signed in to Google again." : "Signed in, but Google still refused. Try Check connection in Settings › Read aloud.")
                        }
                    }
                } else {
                    let last = detail.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
                    Toast.show("Google sign-in didn't finish." + (last.map { " \($0)" } ?? ""))
                }
            }
        }
        do {
            try process.run()
        } catch {
            signingIn = false
            Toast.show("Couldn't start gcloud: \(error.localizedDescription)")
            return
        }
        // Give up if the browser tab is abandoned, so the button comes back.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { if process.isRunning { process.terminate() } }
    }

    private static func process(_ gcloud: URL, _ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = gcloud
        p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // Apps start with a bare PATH; gcloud needs to find python3 and `open`.
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        p.standardInput = FileHandle.nullDevice  // never wait on a prompt nobody can see
        p.standardOutput = FileHandle.nullDevice
        return p
    }

    /// Where gcloud usually lives: Google's installer, or Homebrew.
    static func gcloudPath() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/google-cloud-sdk/bin/gcloud",
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/opt/homebrew/share/google-cloud-sdk/bin/gcloud",
            "/usr/local/share/google-cloud-sdk/bin/gcloud",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}
