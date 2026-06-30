import SwiftUI

struct SettingsView: View {
    @ObservedObject var viewModel: CameraViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Camera") {
                    TextField("Host", text: $viewModel.config.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.numbersAndPunctuation)
                    Stepper("Port: \(viewModel.config.port)", value: $viewModel.config.port, in: 1...65535)
                    Stepper("Stream: \(viewModel.config.stream)", value: $viewModel.config.stream, in: 0...99)
                    TextField("Username", text: $viewModel.config.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $viewModel.config.password)
                }

                Section("Status") {
                    LabeledContent("Rotation", value: "\(viewModel.rotationDegrees)°")
                    LabeledContent("Connection", value: viewModel.status)
                    LabeledContent("Video", value: String(format: "%.0f KB", viewModel.videoKB))
                    LabeledContent("Dropped packets", value: "\(viewModel.droppedPackets)")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
