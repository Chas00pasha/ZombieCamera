import Foundation

/// Parses interleaved RTP (`$` + 8-byte header + RTP) and emits Annex B H.264 (PT 96).
final class RTPVideoDemuxer {
    private static let nalStartCode = Data([0x00, 0x00, 0x00, 0x01])
    private static let videoPayloadType = 96

    private var buffer = Data()
    private var fuaActive = false
    private var fuaNALHeader: UInt8 = 0

    private(set) var videoBytes = 0
    private(set) var videoPackets = 0
    private(set) var droppedPackets = 0
    private(set) var payloadTypeCounts: [UInt8: Int] = [:]

    var onAnnexBData: ((Data) -> Void)?

    func feed(_ chunk: Data) {
        buffer.append(chunk)
        drain()
    }

    private func drain() {
        while true {
            guard buffer.count >= 8 else { return }

            if buffer[0] != 0x24 {
                if let index = buffer.dropFirst().firstIndex(of: 0x24) {
                    buffer.removeSubrange(0..<index)
                    continue
                }
                buffer.removeAll(keepingCapacity: true)
                return
            }

            let packetLength = Int(buffer[6]) << 8 | Int(buffer[7])
            let totalLength = 8 + packetLength
            guard buffer.count >= totalLength else { return }

            let rtpPacket = buffer.subdata(in: 8..<totalLength)
            buffer.removeSubrange(0..<totalLength)
            handleRTP(rtpPacket)
        }
    }

    private func handleRTP(_ rtp: Data) {
        guard rtp.count >= 12 else { return }

        let payloadType = rtp[1] & 0x7F
        payloadTypeCounts[payloadType, default: 0] += 1

        guard payloadType == Self.videoPayloadType else {
            droppedPackets += 1
            return
        }

        handleH264(payload: rtp.subdata(in: 12..<rtp.count))
    }

    private func write(_ data: Data) {
        onAnnexBData?(data)
        videoBytes += data.count
    }

    private func handleH264(payload: Data) {
        guard !payload.isEmpty else { return }

        let nalHeader = payload[0]
        let nalType = nalHeader & 0x1F

        switch nalType {
        case 28:
            guard payload.count >= 2 else { return }
            let fuHeader = payload[1]
            let start = fuHeader & 0x80 != 0
            let end = fuHeader & 0x40 != 0
            let originalType = fuHeader & 0x1F

            if start {
                fuaNALHeader = (nalHeader & 0xE0) | originalType
                write(Self.nalStartCode)
                write(Data([fuaNALHeader]))
                write(payload.subdata(in: 2..<payload.count))
                fuaActive = true
            } else if fuaActive {
                write(payload.subdata(in: 2..<payload.count))
            }

            if end {
                fuaActive = false
            }

        case 24:
            var offset = 1
            while offset + 2 <= payload.count {
                let nalSize = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard offset + nalSize <= payload.count else { break }
                write(Self.nalStartCode)
                write(payload.subdata(in: offset..<(offset + nalSize)))
                offset += nalSize
            }

        default:
            if payload.starts(with: Self.nalStartCode) {
                write(payload)
            } else {
                write(Self.nalStartCode)
                write(payload)
            }
        }

        videoPackets += 1
    }
}
