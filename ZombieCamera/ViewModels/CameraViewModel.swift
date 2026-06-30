import Combine
import CoreVideo
import Foundation

@MainActor
final class CameraViewModel: ObservableObject {
    @Published var config = CameraConfig()
    @Published var status = "Disconnected"
    @Published var isConnected = false
    @Published var isRecording = false
    @Published var videoKB: Double = 0
    @Published var droppedPackets = 0
    @Published var rotationQuarterTurns = 1
    @Published var alertMessage: String?

    let previewSink = VideoPreviewSink()

    private let client = CameraStreamClient()
    private let pipeline = H264Pipeline()
    private let recorder = VideoRecorder()
    private var previewSize: CGSize?

    init() {
        client.onStatus = { [weak self] status in
            Task { @MainActor in
                self?.status = status
                self?.isConnected = status == "Streaming"
            }
        }

        client.onStats = { [weak self] bytes, dropped in
            Task { @MainActor in
                self?.videoKB = Double(bytes) / 1024.0
                self?.droppedPackets = dropped
            }
        }

        client.onAnnexBData = { [weak self] data in
            self?.pipeline.feed(annexB: data)
        }

        pipeline.onPixelBuffer = { [weak self] buffer in
            Task { @MainActor in
                self?.handleFrame(buffer)
            }
        }
    }

    func connect() {
        pipeline.setRotationQuarterTurns(rotationQuarterTurns)
        pipeline.reset()
        previewSink.flush()
        client.connect(config: config)
    }

    func disconnect() {
        if isRecording {
            stopRecording()
        }
        client.disconnect()
        pipeline.reset()
        previewSink.flush()
        isConnected = false
    }

    func toggleConnection() {
        if isConnected {
            disconnect()
        } else {
            connect()
        }
    }

    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    func cycleRotation() {
        rotationQuarterTurns = (rotationQuarterTurns + 1) % 4
        pipeline.setRotationQuarterTurns(rotationQuarterTurns)
    }

    var rotationDegrees: Int {
        rotationQuarterTurns * 90
    }

    private func startRecording() {
        guard let size = previewSize else {
            alertMessage = "Wait for the first video frame before recording"
            return
        }

        do {
            try recorder.start(size: size)
            isRecording = true
            status = "Recording..."
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func stopRecording() {
        recorder.stop { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.isRecording = false
                self.status = self.isConnected ? "Streaming" : "Disconnected"

                switch result {
                case .success(let url):
                    self.recorder.saveToPhotoLibrary(url: url) { saveResult in
                        Task { @MainActor in
                            switch saveResult {
                            case .success:
                                self.alertMessage = "Video saved to Photos"
                            case .failure(let error):
                                self.alertMessage = "Saved to \(url.lastPathComponent), Photos error: \(error.localizedDescription)"
                            }
                        }
                    }
                case .failure(let error):
                    self.alertMessage = error.localizedDescription
                }
            }
        }
    }

    private func handleFrame(_ buffer: CVPixelBuffer) {
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        previewSize = CGSize(width: width, height: height)
        previewSink.display(buffer)

        if recorder.isRecording {
            recorder.append(pixelBuffer: buffer)
        }
    }
}
