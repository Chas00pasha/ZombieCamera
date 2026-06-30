import AVFoundation
import CoreMedia
import Photos
import UIKit

final class VideoRecorder {
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var frameCount: Int64 = 0
    private let fps: Int32 = 15
    private var outputURL: URL?

    var isRecording: Bool { writer != nil }

    func start(naturalSize: CGSize, rotationQuarterTurns: Int) throws {
        let fileName = "camera_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height)
        ]

        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        input.transform = VideoRotation.writerTransform(
            quarterTurns: rotationQuarterTurns,
            naturalSize: naturalSize
        )

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(naturalSize.width),
            kCVPixelBufferHeightKey as String: Int(naturalSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: sourceAttributes
        )

        guard writer.canAdd(input) else {
            throw NSError(domain: "VideoRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot add video input"])
        }

        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.input = input
        self.adaptor = adaptor
        self.frameCount = 0
        self.outputURL = url
    }

    func append(pixelBuffer: CVPixelBuffer) {
        guard let writer, let input, let adaptor, writer.status == .writing else { return }
        guard input.isReadyForMoreMediaData else { return }

        let time = CMTime(value: frameCount, timescale: fps)
        frameCount += 1
        adaptor.append(pixelBuffer, withPresentationTime: time)
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let writer, let input, let url = outputURL else {
            completion(.failure(NSError(domain: "VideoRecorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "Not recording"])))
            return
        }

        input.markAsFinished()
        writer.finishWriting { [weak self] in
            if writer.status == .completed {
                completion(.success(url))
            } else {
                completion(.failure(writer.error ?? NSError(domain: "VideoRecorder", code: 3)))
            }
            self?.writer = nil
            self?.input = nil
            self?.adaptor = nil
            self?.outputURL = nil
        }
    }

    func saveToPhotoLibrary(url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(NSError(domain: "VideoRecorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "Photo library access denied"])))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(error))
                    } else if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(NSError(domain: "VideoRecorder", code: 5)))
                    }
                }
            })
        }
    }
}
