import Foundation
import NexusCore

/// Never forwards the URL or session to a redirected origin. The user must
/// invoke this from an individual history-card context menu after turning on
/// the separate privacy toggle. Default automatic behavior is fully offline.
private final class NexusRemoteTitleNoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum ClipboardRemoteWebTitleFetcher {
    static func fetch(from copiedText: String) async throws -> String? {
        guard let url = ClipboardRemoteWebTitlePolicy.eligibleURL(copiedText)
        else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        let session = URLSession(
            configuration: config,
            delegate: NexusRemoteTitleNoRedirects(),
            delegateQueue: nil
        )
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        let (stream, response) = try await session.bytes(for: request)
        guard let result = response as? HTTPURLResponse,
              result.statusCode == 200,
              let contentType = result.value(
                forHTTPHeaderField: "Content-Type"
              )?.lowercased(),
              contentType.hasPrefix("text/html"),
              (response.expectedContentLength < 0 ||
               response.expectedContentLength <= Int64(ClipboardRemoteWebTitlePolicy.maximumHTMLBytes))
        else { return nil }

        var data = Data()
        data.reserveCapacity(16 * 1024)
        for try await byte in stream {
            try Task.checkCancellation()
            guard data.count < ClipboardRemoteWebTitlePolicy.maximumHTMLBytes
            else { return nil }
            data.append(byte)
        }
        return ClipboardRemoteWebTitlePolicy.title(
            fromHTML: data, copiedText: copiedText
        )
    }
}
