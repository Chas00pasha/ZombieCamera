import AVFoundation

final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "mic.capture", qos: .userInitiated)

    var onAudioSample: ((CMSampleBuffer) -> Void)?

    private var audioSessionOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
        // .allowBluetoothHFP есть только в новых SDK; .allowBluetooth работает на Xcode 14+ и с BT-петличками
        options.insert(.allowBluetooth)
        return options
    }

    func start() throws {
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .videoRecording,
            options: audioSessionOptions
        )
        try audioSession.setActive(true)

        guard let device = AVCaptureDevice.default(for: .audio) else {
            throw NSError(domain: "MicrophoneCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Microphone not available"
            ])
        }

        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.sessionPreset = .high

        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            throw NSError(domain: "MicrophoneCapture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add microphone input"
            ])
        }

        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            session.commitConfiguration()
            throw NSError(domain: "MicrophoneCapture", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add audio output"
            ])
        }

        session.commitConfiguration()
        session.startRunning()
    }

    func stop() {
        session.stopRunning()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onAudioSample?(sampleBuffer)
    }
}
