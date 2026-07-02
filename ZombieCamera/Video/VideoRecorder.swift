import AVFoundation
import CoreMedia
import Photos
import UIKit

final class VideoRecorder {
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var microphone = MicrophoneCapture()
    private var frameCount: Int64 = 0
    private var audioSampleCount = 0
    private let fps: Int32 = 15
    private var outputURL: URL?
    private var sessionStartTime: CMTime?

    var isRecording: Bool { writer != nil }

    func start(naturalSize: CGSize, rotationQuarterTurns: Int) throws {
        let width = max(2, Int(naturalSize.width) & ~1)
        let height = max(2, Int(naturalSize.height) & ~1)
        let evenSize = CGSize(width: width, height: height)

        let fileName = "camera_\(Int(Date().timeIntervalSince1970)).mp4"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = VideoRotation.writerTransform(
            quarterTurns: rotationQuarterTurns,
            naturalSize: evenSize
        )

        let sourceAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourceAttributes
        )

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true

        guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
            throw NSError(domain: "VideoRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add recorder inputs"
            ])
        }

        writer.add(videoInput)
        writer.add(audioInput)

        frameCount = 0
        audioSampleCount = 0
        sessionStartTime = nil

        microphone.onAudioSample = { [weak self] sampleBuffer in
            self?.appendAudio(sampleBuffer)
        }
        try microphone.start()

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.adaptor = adaptor
        self.outputURL = url
    }

    func append(pixelBuffer: CVPixelBuffer) {
        guard let writer, let videoInput, let adaptor, writer.status == .writing else { return }
        guard videoInput.isReadyForMoreMediaData else { return }

        let time = CMTime(value: frameCount, timescale: fps)
        if adaptor.append(pixelBuffer, withPresentationTime: time) {
            frameCount += 1
        }
    }

    private func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let writer, let audioInput, writer.status == .writing else { return }
        guard audioInput.isReadyForMoreMediaData else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if sessionStartTime == nil {
            sessionStartTime = pts
        }
        guard let sessionStartTime,
              let adjusted = retimestamp(sampleBuffer, baseTime: sessionStartTime) else {
            return
        }

        if audioInput.append(adjusted) {
            audioSampleCount += 1
        }
    }

    func stop(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let writer, let videoInput, let url = outputURL else {
            completion(.failure(NSError(domain: "VideoRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Not recording"
            ])))
            return
        }

        microphone.stop()
        microphone.onAudioSample = nil

        videoInput.markAsFinished()
        audioInput?.markAsFinished()

        writer.finishWriting { [weak self] in
            guard let self else { return }

            Task {
                let result: Result<URL, Error>
                if writer.status == .completed, self.frameCount > 0 {
                    if await self.validateVideoFile(at: url) {
                        result = .success(url)
                    } else {
                        result = .failure(NSError(domain: "VideoRecorder", code: 6, userInfo: [
                            NSLocalizedDescriptionKey: "Recorded file is invalid or empty"
                        ]))
                    }
                } else if self.frameCount == 0 {
                    result = .failure(NSError(domain: "VideoRecorder", code: 7, userInfo: [
                        NSLocalizedDescriptionKey: "No video frames were recorded"
                    ]))
                } else {
                    result = .failure(writer.error ?? NSError(domain: "VideoRecorder", code: 3))
                }

                self.writer = nil
                self.videoInput = nil
                self.audioInput = nil
                self.adaptor = nil
                self.outputURL = nil
                self.sessionStartTime = nil

                completion(result)
            }
        }
    }

    private func validateVideoFile(at url: URL) async -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 1024 else {
            return false
        }

        let asset = AVURLAsset(url: url)
        guard let isPlayable = try? await asset.load(.isPlayable),
              isPlayable,
              let duration = try? await asset.load(.duration),
              duration.seconds > 0.1 else {
            return false
        }
        return true
    }

    func saveToPhotoLibrary(url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        Task {
            guard await validateVideoFile(at: url) else {
                await MainActor.run {
                    completion(.failure(NSError(domain: "VideoRecorder", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "Cannot save invalid video to Photos"
                    ])))
                }
                return
            }

            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                completion(.failure(NSError(domain: "VideoRecorder", code: 4, userInfo: [
                    NSLocalizedDescriptionKey: "Photo library access denied"
                ])))
                return
            }

            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: url, options: nil)
            }, completionHandler: { success, error in
                DispatchQueue.main.async {
                    if let error {
                        completion(.failure(error))
                    } else if success {
                        completion(.success(()))
                    } else {
                        completion(.failure(NSError(domain: "VideoRecorder", code: 5, userInfo: [
                            NSLocalizedDescriptionKey: "Photos save failed"
                        ])))
                    }
                }
            })
        }
    }

    private func retimestamp(_ sampleBuffer: CMSampleBuffer, baseTime: CMTime) -> CMSampleBuffer? {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let relativePTS = CMTimeSubtract(pts, baseTime)
        guard CMTimeCompare(relativePTS, .zero) >= 0 else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(sampleBuffer),
            presentationTimeStamp: relativePTS,
            decodeTimeStamp: .invalid
        )

        var output: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &output
        )
        guard status == noErr else { return nil }
        return output
    }
}
