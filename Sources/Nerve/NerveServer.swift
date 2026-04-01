#if DEBUG

import Foundation
import Network
import os

// MARK: - WebSocket Server

final class NerveServer {
    private let port: UInt16
    private weak var engine: NerveEngine?
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let maxConnections = 10
    private let queue = DispatchQueue(label: "com.nerve.server")

    init(port: UInt16, engine: NerveEngine) {
        self.port = port
        self.engine = engine
    }

    func start() {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        } catch {
            os_log("[Nerve] Failed to create listener: %{public}@", error.localizedDescription)
            return
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener?.port?.rawValue {
                    os_log("[Nerve] WebSocket server ready on port %d", port)
                }
            case .failed(let error):
                os_log("[Nerve] Listener failed: %{public}@", error.localizedDescription)
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        connections.forEach { $0.cancel() }
        connections.removeAll()
        listener?.cancel()
    }

    func send(_ response: NerveResponse) {
        guard !connections.isEmpty else { return }
        let data = Data(response.toJSON().utf8)
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "nerve", metadata: [metadata])
        for connection in connections {
            connection.send(content: data, contentContext: context, completion: .contentProcessed({ error in
                if let error {
                    os_log("[Nerve] Send error: %{public}@", error.localizedDescription)
                }
            }))
        }
    }

    private func handleNewConnection(_ connection: NWConnection) {
        guard connections.count < maxConnections else {
            os_log("[Nerve] Max connections reached, rejecting new connection")
            connection.cancel()
            return
        }

        connections.append(connection)

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                os_log("[Nerve] Client connected (%d total)", self?.connections.count ?? 0)
                self?.receiveMessage(on: connection)
            case .failed(let error):
                os_log("[Nerve] Connection failed: %{public}@", error.localizedDescription)
                self?.connections.removeAll { $0 === connection }
            case .cancelled:
                os_log("[Nerve] Client disconnected")
                self?.connections.removeAll { $0 === connection }
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func receiveMessage(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let error {
                os_log("[Nerve] Receive error: %{public}@", error.localizedDescription)
                return
            }

            if let data, let command = try? JSONDecoder().decode(NerveCommand.self, from: data) {
                Task {
                    let response = await self.engine?.handleCommand(command)
                        ?? .error(command.id, "Engine not available")
                    self.send(response)
                }
            }

            if connection.state == .ready {
                self.receiveMessage(on: connection)
            }
        }
    }

}

#endif
