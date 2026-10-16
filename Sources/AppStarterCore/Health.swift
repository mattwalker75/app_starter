// Is an application up? A URL check: the address answers at all — any status, any certificate (your own apps
// often use a self-signed or Tailscale certificate). An output check: the command's output contains the text.
// Apps without a check that can be run again are judged by what App Starter knows: a kept-running process is
// alive, or the last start worked and nothing has stopped it since.
import Foundation

public enum Health {
    /// Does anything answer at this address within `timeout` seconds?
    public static func urlAnswers(_ address: String, timeout: Double = 3) async -> Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespaces)) else { return false }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        req.httpMethod = "GET"
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout; cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg, delegate: AnyCertificate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do { let (_, r) = try await session.data(for: req); return r is HTTPURLResponse }
        catch { return false }
    }

    /// Runs the command; true when its output contains the text.
    public static func outputContains(_ command: Command, text: String, ignoreCase: Bool, timeout: Double = 15) async -> Bool {
        let r = await Shell.run(command, log: nil, timeout: timeout)
        guard !r.timedOut else { return false }
        return ignoreCase ? r.output.range(of: text, options: .caseInsensitive) != nil : r.output.contains(text)
    }

    /// The health check, run now (for checks that can be run again). nil = this app's check can't be run on its own.
    public static func poll(_ app: AppItem) async -> Bool? {
        switch app.health {
        case .url(let u): return await urlAnswers(u)
        case .output(let c, let t, let i): return await outputContains(Command(c, for: app), text: t, ignoreCase: i)
        case .none, .returnCode: return nil
        }
    }
}

/// Accepts any server certificate: the check only asks "does it answer?", it never sends anything that matters.
private final class AnyCertificate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let t = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: t))
        }
        return (.performDefaultHandling, nil)
    }
    // a redirect is an answer too: stop there instead of following it
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? { nil }
}
