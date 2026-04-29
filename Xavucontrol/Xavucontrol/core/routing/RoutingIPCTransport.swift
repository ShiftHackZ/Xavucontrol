import Foundation

struct RoutingIPCReceipt: Hashable {
    var messageID: String
    var summary: String
    var routerSummary: String
}

protocol RoutingIPCTransport {
    func send(_ message: RoutingIPCMessage) async throws -> RoutingIPCReceipt
}

struct RoutingCommandQueueTransport: RoutingIPCTransport {
    private let encoder = JSONEncoder()
    private let routerService = RoutingRouterService.shared

    func send(_ message: RoutingIPCMessage) async throws -> RoutingIPCReceipt {
        let envelope = RoutingCommandEnvelope(message: message)
        let directoryURL = try commandQueueDirectoryURL()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let queueURL = directoryURL.appendingPathComponent("routing-commands.jsonl")
        let payload = try encoder.encode(envelope)
        var line = payload
        line.append(0x0A)

        if FileManager.default.fileExists(atPath: queueURL.path) {
            let handle = try FileHandle(forWritingTo: queueURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: queueURL)
        }

        let routerResult = await routerService.handle(message)
        return RoutingIPCReceipt(
            messageID: envelope.id,
            summary: "queued command \(envelope.id)",
            routerSummary: routerResult.displayText
        )
    }

    private func commandQueueDirectoryURL() throws -> URL {
        let baseURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return baseURL.appendingPathComponent("xavucontrol-macos", isDirectory: true)
    }
}

struct RoutingCommandEnvelope: Codable, Hashable {
    var id: String
    var createdAt: Date
    var message: RoutingIPCMessage

    init(message: RoutingIPCMessage) {
        self.id = UUID().uuidString
        self.createdAt = Date()
        self.message = message
    }
}
