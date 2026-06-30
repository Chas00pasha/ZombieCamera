import AVFoundation
import CoreGraphics
import UIKit

enum VideoRotation {
    static func normalizedQuarterTurns(_ turns: Int) -> Int {
        ((turns % 4) + 4) % 4
    }

    /// ffmpeg `transpose=1` — 90° clockwise.
    static func writerTransform(quarterTurns: Int, naturalSize: CGSize) -> CGAffineTransform {
        let width = naturalSize.width
        let height = naturalSize.height

        switch normalizedQuarterTurns(quarterTurns) {
        case 1:
            return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: width, ty: 0)
        case 2:
            return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: width, ty: height)
        case 3:
            return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: width)
        default:
            return .identity
        }
    }

    static func applyPreviewLayout(
        container: UIView,
        displayLayer: AVSampleBufferDisplayLayer,
        in bounds: CGRect,
        quarterTurns: Int
    ) {
        let turns = normalizedQuarterTurns(quarterTurns)
        container.transform = .identity

        switch turns {
        case 1:
            container.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            container.center = CGPoint(x: bounds.midX, y: bounds.midY)
            container.transform = CGAffineTransform(rotationAngle: .pi / 2)
        case 2:
            container.frame = bounds
            container.transform = CGAffineTransform(rotationAngle: .pi)
        case 3:
            container.bounds = CGRect(x: 0, y: 0, width: bounds.height, height: bounds.width)
            container.center = CGPoint(x: bounds.midX, y: bounds.midY)
            container.transform = CGAffineTransform(rotationAngle: -.pi / 2)
        default:
            container.frame = bounds
        }

        displayLayer.frame = container.bounds
    }
}
