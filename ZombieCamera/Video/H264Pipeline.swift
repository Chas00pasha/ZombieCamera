import CoreMedia
import CoreVideo
import VideoToolbox

final class H264Pipeline {
    private let queue = DispatchQueue(label: "h264.pipeline", qos: .userInitiated)
    private var buffer = Data()
    private var formatDescription: CMFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var sps: Data?
    private var pps: Data?

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    func reset() {
        queue.async {
            self.buffer.removeAll(keepingCapacity: true)
            self.formatDescription = nil
            self.sps = nil
            self.pps = nil
            if let session = self.decompressionSession {
                VTDecompressionSessionInvalidate(session)
            }
            self.decompressionSession = nil
        }
    }

    func feed(annexB data: Data) {
        queue.async {
            self.buffer.append(data)
            self.processNALUnits()
        }
    }

    private func processNALUnits() {
        while let extracted = extractNextNALUnit(from: buffer) {
            buffer.removeSubrange(0..<extracted.consumed)
            let nalUnit = extracted.nalUnit
            guard !nalUnit.isEmpty else { continue }

            let nalType = nalUnit[0] & 0x1F
            switch nalType {
            case 7:
                sps = nalUnit
            case 8:
                pps = nalUnit
                updateFormatDescriptionIfPossible()
            case 1, 5:
                decodeAccessUnit(nalUnit)
            default:
                break
            }
        }
    }

    private func extractNextNALUnit(from data: Data) -> (nalUnit: Data, consumed: Int)? {
        guard let start = findStartCode(in: data, from: 0) else { return nil }
        let headerLength = startCodeLength(in: data, at: start)
        let nalStart = start + headerLength
        guard nalStart < data.count else { return nil }

        if let next = findStartCode(in: data, from: nalStart) {
            let nalUnit = data.subdata(in: nalStart..<next)
            return (nalUnit, next)
        }

        return nil
    }

    private func findStartCode(in data: Data, from offset: Int) -> Int? {
        guard offset < data.count else { return nil }
        var index = offset
        while index + 2 < data.count {
            if data[index] == 0x00, data[index + 1] == 0x00 {
                if data[index + 2] == 0x01 {
                    return index
                }
                if index + 3 < data.count, data[index + 2] == 0x00, data[index + 3] == 0x01 {
                    return index
                }
            }
            index += 1
        }
        return nil
    }

    private func startCodeLength(in data: Data, at index: Int) -> Int {
        if index + 3 < data.count,
           data[index] == 0x00, data[index + 1] == 0x00,
           data[index + 2] == 0x00, data[index + 3] == 0x01 {
            return 4
        }
        return 3
    }

    private func updateFormatDescriptionIfPossible() {
        guard let sps, let pps else { return }

        var newDescription: CMFormatDescription?
        let status = sps.withUnsafeBytes { spsRaw in
            pps.withUnsafeBytes { ppsRaw in
                guard let spsPointer = spsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let ppsPointer = ppsRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return OSStatus(-1)
                }
                let pointers = [spsPointer, ppsPointer]
                let sizes = [sps.count, pps.count]
                return pointers.withUnsafeBufferPointer { pointerBuffer in
                    sizes.withUnsafeBufferPointer { sizeBuffer in
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBuffer.baseAddress!,
                            parameterSetSizes: sizeBuffer.baseAddress!,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &newDescription
                        )
                    }
                }
            }
        }

        guard status == noErr, let newDescription else { return }

        formatDescription = newDescription
        if let session = decompressionSession {
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        createDecompressionSession(format: newDescription)
    }

    private func createDecompressionSession(format: CMFormatDescription) {
        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: Self.decompressionCallback,
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        var session: VTDecompressionSession?
        let attributes: [NSString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]

        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: format,
            decoderSpecification: nil,
            imageBufferAttributes: attributes as CFDictionary,
            outputCallback: &callback,
            decompressionSessionOut: &session
        )

        if status == noErr {
            decompressionSession = session
        }
    }

    private func decodeAccessUnit(_ nalUnit: Data) {
        guard let formatDescription, let session = decompressionSession else { return }

        let avcc = annexBUnitToAVCC(nalUnit)
        guard !avcc.isEmpty else { return }

        var blockBuffer: CMBlockBuffer?
        let status = avcc.withUnsafeBytes { rawBuffer -> OSStatus in
            guard let base = rawBuffer.baseAddress else { return -1 }
            let localStatus = CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: avcc.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: avcc.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            )
            guard localStatus == kCMBlockBufferNoErr, let blockBuffer else { return localStatus }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == kCMBlockBufferNoErr, let blockBuffer else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = avcc.count
        CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 0,
            sampleTimingArray: nil,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard let sampleBuffer else { return }

        var infoFlags = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: nil,
            infoFlagsOut: &infoFlags
        )
    }

    fileprivate func handleDecodedFrame(_ imageBuffer: CVImageBuffer) {
        onPixelBuffer?(imageBuffer)
    }

    private func annexBUnitToAVCC(_ unit: Data) -> Data {
        var result = Data()
        var length = UInt32(unit.count).bigEndian
        result.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        result.append(unit)
        return result
    }

    private static let decompressionCallback: VTDecompressionOutputCallback = {
        decompressionOutputRefCon,
        _,
        status,
        _,
        imageBuffer,
        _,
        _ in
        guard status == noErr,
              let imageBuffer,
              let refCon = decompressionOutputRefCon else {
            return
        }
        let pipeline = Unmanaged<H264Pipeline>.fromOpaque(refCon).takeUnretainedValue()
        pipeline.handleDecodedFrame(imageBuffer)
    }
}
