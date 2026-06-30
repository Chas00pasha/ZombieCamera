import Foundation

enum CameraStreamError: LocalizedError {
    case invalidURL
    case handshakeFailed(String)
    case notConnected
    case closedByServer

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid WebSocket URL"
        case .handshakeFailed(let response):
            return "Camera handshake failed: \(response)"
        case .notConnected:
            return "Not connected to camera"
        case .closedByServer:
            return "Camera closed the stream"
        }
    }
}

final class CameraStreamClient {
    private let queue = DispatchQueue(label: "camera.stream", qos: .userInitiated)
    private var webSocket: URLSessionWebSocketTask?
    private var session: URLSession?
    private var demuxer = RTPVideoDemuxer()
    private var isRunning = false

    var onStatus: ((String) -> Void)?
    var onStats: ((Int, Int) -> Void)?
    var onAnnexBData: ((Data) -> Void)?

    func connect(config: CameraConfig) {
        queue.async { [weak self] in
            self?.connectInternal(config: config)
        }
    }

    func disconnect() {
        queue.async { [weak self] in
            self?.stopInternal()
        }
    }

    private func connectInternal(config: CameraConfig) {
        stopInternal()

        guard let url = URL(string: "ws://\(config.host):\(config.port)/websocket") else {
            publishStatus("Invalid URL")
            return
        }

        demuxer = RTPVideoDemuxer()
        demuxer.onAnnexBData = { [weak self] data in
            self?.onAnnexBData?(data)
        }

        let session = URLSession(configuration: .default)
        self.session = session
        let socket = session.webSocketTask(with: url)
        webSocket = socket
        isRunning = true

        publishStatus("Connecting to \(url.host ?? config.host)...")
        socket.resume()

        let handshake = CameraHandshake.buildCommand(config: config)
        socket.send(.string(handshake)) { [weak self] error in
            if let error {
                self?.publishStatus("Send error: \(error.localizedDescription)")
                self?.stopInternal()
                return
            }
            self?.receiveHandshakeResponse(socket: socket)
        }
    }

    private func receiveHandshakeResponse(socket: URLSessionWebSocketTask) {
        socket.receive { [weak self] result in
            guard let self, self.isRunning else { return }

            switch result {
            case .failure(let error):
                self.publishStatus("Handshake error: \(error.localizedDescription)")
                self.stopInternal()

            case .success(let message):
                let text: String
                switch message {
                case .string(let value):
                    text = value
                case .data(let data):
                    text = String(data: data, encoding: .utf8) ?? ""
                @unknown default:
                    text = ""
                }

                guard text.contains("200 OK") else {
                    self.publishStatus("Handshake failed")
                    self.onStatus?("Handshake failed:\n\(text)")
                    self.stopInternal()
                    return
                }

                self.publishStatus("Streaming")
                self.receiveStream()
                self.startStatsTimer()
            }
        }
    }

    private func receiveStream() {
        guard isRunning, let socket = webSocket else { return }

        socket.receive { [weak self] result in
            guard let self, self.isRunning else { return }

            switch result {
            case .failure(let error):
                self.publishStatus("Stream error: \(error.localizedDescription)")
                self.stopInternal()

            case .success(let message):
                switch message {
                case .data(let data):
                    if !data.isEmpty {
                        self.demuxer.feed(data)
                    }
                case .string:
                    break
                @unknown default:
                    break
                }
                self.receiveStream()
            }
        }
    }

    private func startStatsTimer() {
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isRunning else { return }
            self.onStats?(self.demuxer.videoBytes, self.demuxer.droppedPackets)
            self.startStatsTimer()
        }
    }

    private func stopInternal() {
        isRunning = false
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        session?.invalidateAndCancel()
        session = nil
        publishStatus("Disconnected")
    }

    private func publishStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatus?(status)
        }
    }
}
