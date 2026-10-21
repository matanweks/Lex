#if DEBUG
import Foundation
import LexCore

/// Test support: answers Claude requests with canned text, so the app, the share sheet and
/// Shortcuts can be tried in the Simulator without an API key. Launching the app with
/// `-LexStubClaude YES` turns it on and `NO` off; the share sheet and Shortcuts follow.
final class StubClaude: URLProtocol {
    static var isOn: Bool { AppGroup.defaults.bool(forKey: "debugStubClaude") }

    /// Reads the launch argument and shares it with the extensions. A launch without it (iOS
    /// starting Lex for a shortcut) leaves the setting as it was.
    static func configure() {
        guard UserDefaults.standard.object(forKey: "LexStubClaude") != nil else { return }
        AppGroup.defaults.set(UserDefaults.standard.bool(forKey: "LexStubClaude"), forKey: "debugStubClaude")
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "api.anthropic.com" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["content-type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var sse = ""
        for word in Self.answer(to: body()).split(separator: " ", omittingEmptySubsequences: false) {
            let delta = ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": word + " "]] as [String: Any]
            sse += "data: " + String(decoding: try! JSONSerialization.data(withJSONObject: delta), as: UTF8.self) + "\n\n"
        }
        sse += "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}\n\n"
        client?.urlProtocol(self, didLoad: Data(sse.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func body() -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Echoes the text with a tag naming what was asked, so a test can see which action ran.
    static func answer(to body: [String: Any]) -> String {
        let user = ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        func tag(_ name: String) -> String? {
            guard let open = user.range(of: "<\(name)>"), let close = user.range(of: "</\(name)>", range: open.upperBound..<user.endIndex) else { return nil }
            return String(user[open.upperBound..<close.lowerBound])
        }
        if let transcript = tag("transcript") {
            let tidy = transcript.replacingOccurrences(of: "um ", with: "").trimmingCharacters(in: .whitespaces)
            return tidy.prefix(1).uppercased() + tidy.dropFirst() + (tidy.hasSuffix(".") ? "" : ".")
        }
        if let message = tag("message") { return "Stub: \(message.count) characters that read friendly and clear." }
        let instruction = (tag("instruction") ?? "").split(separator: " ").prefix(3).joined(separator: " ")
        return "[\(instruction)] \(tag("text") ?? "")"
    }
}
#endif
