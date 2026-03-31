#if DEBUG

import Foundation
import UIKit

// MARK: - Console Commands

extension NerveEngine {

    func handleConsole(_ command: NerveCommand) -> NerveResponse {
        let limit = command.intParam("limit") ?? 50
        let filter = command.stringParam("filter")
        let level = command.stringParam("level")
        let since = command.stringParam("since")

        var logs = console.recentLogs(limit: limit)

        if since == "last_action", let actionTime = lastActionTime {
            logs = logs.filter { $0.timestamp >= actionTime }
        }

        if let filter {
            logs = logs.filter { $0.message.localizedCaseInsensitiveContains(filter) }
        }

        if let level {
            let minLevel = NerveConsole.LogLevel(rawValue: level) ?? .debug
            logs = logs.filter { $0.level.priority >= minLevel.priority }
        }

        var lines = ["console: \(console.totalCount) lines (showing \(logs.count))", "---"]
        for log in logs {
            lines.append("\(log.formattedTimestamp) [\(log.level.rawValue)] \(log.message)")
        }

        return .success(command.id, lines.joined(separator: "\n"))
    }

    func handleNetwork(_ command: NerveCommand) -> NerveResponse {
        let limit = command.intParam("limit") ?? 20
        let filter = command.stringParam("filter")
        let index = command.intParam("index")

        let transactions = NerveNetworkStore.shared.recent(limit: index != nil ? 500 : limit, urlFilter: filter)

        // Detail view for a specific transaction
        if let index {
            guard index >= 1 && index <= transactions.count else {
                return .error(command.id, "Invalid index \(index). Valid range: 1-\(transactions.count)")
            }
            let tx = transactions[index - 1]
            var lines = ["\(tx.method) \(tx.urlString)",
                         "status: \(tx.statusCode.map { "\($0)" } ?? "pending")",
                         "duration: \(tx.duration.map { "\(Int($0 * 1000))ms" } ?? "pending")"]
            if let headers = tx.responseHeaders {
                lines.append("--- response headers ---")
                for (k, v) in headers.sorted(by: { $0.key < $1.key }) {
                    lines.append("  \(k): \(v)")
                }
            }
            if let body = tx.responseBody {
                lines.append("--- response body (\(nerveFormatBytes(Int64(body.count)))) ---")
                if let json = try? JSONSerialization.jsonObject(with: body),
                   let pretty = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                   let str = String(data: pretty, encoding: .utf8) {
                    lines.append(str)
                } else if let str = String(data: body, encoding: .utf8) {
                    lines.append(String(str.prefix(4096)))
                } else {
                    lines.append("<binary data, \(nerveFormatBytes(Int64(body.count)))>")
                }
            } else if tx.responseBodySize > Int64(NerveNetworkStore.shared.maxBodySize) {
                lines.append("--- body too large to capture (\(nerveFormatBytes(tx.responseBodySize))) ---")
            }
            return .success(command.id, lines.joined(separator: "\n"))
        }

        // List view
        let total = NerveNetworkStore.shared.count
        var lines = ["network: \(total) transactions (showing \(transactions.count))", "---"]
        for (i, tx) in transactions.enumerated() {
            let bodySize = nerveFormatBytes(tx.responseBodySize)
            let statusStr = tx.statusCode.map { "\($0)" } ?? "pending"
            let durationStr = tx.duration.map { "\(Int($0 * 1000))ms" } ?? "..."
            lines.append("#\(i + 1) \(tx.method) \(tx.urlString) → \(statusStr) (\(durationStr)) \(bodySize)")
        }

        return .success(command.id, lines.joined(separator: "\n"))
    }
}

// MARK: - Console Capture

final class NerveConsole {
    struct LogEntry {
        let timestamp: Date
        let level: LogLevel
        let message: String

        var formattedTimestamp: String {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm:ss.SSS"
            return formatter.string(from: timestamp)
        }
    }

    enum LogLevel: String {
        case debug, info, warning, error

        var priority: Int {
            switch self {
            case .debug: return 0
            case .info: return 1
            case .warning: return 2
            case .error: return 3
            }
        }
    }

    private var logs: [LogEntry] = []
    private let maxLogs = 1000
    private let lock = NSLock()
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var originalStdout: Int32 = -1
    private var originalStderr: Int32 = -1

    var totalCount: Int { lock.withLock { logs.count } }

    func start() { captureStdout() }
    func stop() { restoreStdout() }

    func addLog(_ message: String, level: LogLevel = .info) {
        lock.withLock {
            logs.append(LogEntry(timestamp: Date(), level: level, message: message))
            if logs.count > maxLogs {
                logs.removeFirst(logs.count - maxLogs)
            }
        }
    }

    func recentLogs(limit: Int) -> [LogEntry] {
        lock.withLock { Array(logs.suffix(limit)) }
    }

    private func captureStdout() {
        stdoutPipe = Pipe()
        stderrPipe = Pipe()
        originalStdout = dup(STDOUT_FILENO)
        originalStderr = dup(STDERR_FILENO)

        guard let stdoutPipe, let stderrPipe else { return }

        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let fd = self?.originalStdout, fd >= 0 {
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
            }
            if let str = String(data: data, encoding: .utf8) {
                for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self?.addLog(trimmed, level: .info) }
                }
            }
        }

        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty { return }
            if let fd = self?.originalStderr, fd >= 0 {
                _ = data.withUnsafeBytes { write(fd, $0.baseAddress!, data.count) }
            }
            if let str = String(data: data, encoding: .utf8) {
                for line in str.split(separator: "\n", omittingEmptySubsequences: false) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { self?.addLog(trimmed, level: .error) }
                }
            }
        }
    }

    private func restoreStdout() {
        if originalStdout >= 0 { dup2(originalStdout, STDOUT_FILENO); close(originalStdout); originalStdout = -1 }
        if originalStderr >= 0 { dup2(originalStderr, STDERR_FILENO); close(originalStderr); originalStderr = -1 }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
    }
}

// MARK: - Network Store

final class NerveNetworkStore {
    static let shared = NerveNetworkStore()

    struct Transaction {
        let id: String
        let method: String
        let urlString: String
        var statusCode: Int?
        var responseBodySize: Int64 = 0
        var duration: TimeInterval?
        let startTime: Date
        var endTime: Date?
        var responseBody: Data?
        var responseHeaders: [String: String]?
    }

    /// Max response body size to store (256KB)
    let maxBodySize = 256 * 1024

    private var transactions: [Transaction] = []
    private let maxTransactions = 500
    private let lock = NSLock()

    var count: Int { lock.withLock { transactions.count } }

    var pendingCount: Int {
        lock.withLock { transactions.filter { $0.endTime == nil }.count }
    }

    func record(_ tx: Transaction) {
        lock.withLock {
            transactions.append(tx)
            if transactions.count > maxTransactions {
                transactions.removeFirst(transactions.count - maxTransactions)
            }
        }
    }

    func update(id: String, statusCode: Int, bodySize: Int64, body: Data? = nil, headers: [String: String]? = nil) {
        lock.withLock {
            if let idx = transactions.lastIndex(where: { $0.id == id }) {
                transactions[idx].statusCode = statusCode
                transactions[idx].responseBodySize = bodySize
                transactions[idx].endTime = Date()
                transactions[idx].duration = Date().timeIntervalSince(transactions[idx].startTime)
                transactions[idx].responseBody = body
                transactions[idx].responseHeaders = headers
            }
        }
    }

    func recent(limit: Int, urlFilter: String? = nil) -> [Transaction] {
        lock.withLock {
            var filtered = transactions
            if let filter = urlFilter {
                filtered = filtered.filter { $0.urlString.localizedCaseInsensitiveContains(filter) }
            }
            return Array(filtered.suffix(limit))
        }
    }
}

// MARK: - URL Protocol

class NerveURLProtocol: URLProtocol {
    private static let handledKey = "NerveURLProtocolHandled"
    private var dataTask: URLSessionDataTask?
    private var receivedData = Data()
    private var response: URLResponse?
    private var txId: String?

    override class func canInit(with request: URLRequest) -> Bool {
        if URLProtocol.property(forKey: handledKey, in: request) != nil { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let mutable = (request as NSURLRequest).mutableCopy() as! NSMutableURLRequest
        URLProtocol.setProperty(true, forKey: Self.handledKey, in: mutable)

        let id = UUID().uuidString
        txId = id
        let tx = NerveNetworkStore.Transaction(
            id: id, method: request.httpMethod ?? "GET",
            urlString: request.url?.absoluteString ?? "?", startTime: Date()
        )
        NerveNetworkStore.shared.record(tx)

        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        dataTask = session.dataTask(with: mutable as URLRequest)
        dataTask?.resume()
    }

    override func stopLoading() { dataTask?.cancel() }
}

extension NerveURLProtocol: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        receivedData.append(data)
        client?.urlProtocol(self, didLoad: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let id = txId {
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0
            let headers = httpResponse?.allHeaderFields as? [String: String]
            let body = receivedData.count <= NerveNetworkStore.shared.maxBodySize ? receivedData : nil
            NerveNetworkStore.shared.update(id: id, statusCode: statusCode, bodySize: Int64(receivedData.count), body: body, headers: headers)
        }
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
    }
}

#endif
