import AVFoundation
import SwiftUI
import UIKit

/// Delivers frames directly to the preview layer, bypassing SwiftUI state diffing.
final class VideoPreviewSink {
    weak var view: PreviewUIView?

    func display(_ pixelBuffer: CVPixelBuffer) {
        DispatchQueue.main.async { [weak self] in
            self?.view?.display(pixelBuffer: pixelBuffer)
        }
    }

    func flush() {
        DispatchQueue.main.async { [weak self] in
            self?.view?.flush()
        }
    }
}

struct VideoPreviewView: UIViewRepresentable {
    let sink: VideoPreviewSink

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        sink.view = view
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        sink.view = uiView
    }
}

final class PreviewUIView: UIView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private var frameIndex: Int64 = 0
    private let timescale: Int32 = 30

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(displayLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }

    func flush() {
        displayLayer.flushAndRemoveImage()
        frameIndex = 0
    }

    func display(pixelBuffer: CVPixelBuffer) {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        )
        guard let formatDescription else { return }

        let pts = CMTime(value: frameIndex, timescale: timescale)
        frameIndex += 1

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: timescale),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else { return }

        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        displayLayer.enqueue(sampleBuffer)
    }
}
