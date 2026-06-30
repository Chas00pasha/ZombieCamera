import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = CameraViewModel()
    @State private var showSettings = false

    var body: some View {
        ZStack {
            VideoPreviewView(sink: viewModel.previewSink)
                .ignoresSafeArea()

            overlayControls
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: viewModel)
        }
        .alert("Info", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }

    private var overlayControls: some View {
        VStack {
            HStack {
                Spacer()
                VStack(spacing: 10) {
                    topButton(
                        icon: "gearshape.fill",
                        label: "Settings"
                    ) {
                        showSettings = true
                    }

                    topButton(
                        icon: viewModel.isConnected ? "wifi.slash" : "wifi",
                        label: viewModel.isConnected ? "Disconnect" : "Connect",
                        tint: viewModel.isConnected ? .green : .white
                    ) {
                        viewModel.toggleConnection()
                    }
                    .disabled(viewModel.isRecording)

                    topButton(
                        icon: "rotate.right",
                        label: "Rotate"
                    ) {
                        viewModel.cycleRotation()
                    }
                }
                .padding(.trailing, 16)
                .padding(.top, 8)
            }

            Spacer()

            recordButton
                .padding(.bottom, 40)
        }
    }

    private func topButton(icon: String, label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                Text(label)
                    .font(.caption2)
            }
            .foregroundStyle(tint)
            .frame(width: 72, height: 56)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }

    private var recordButton: some View {
        Button {
            viewModel.toggleRecording()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 76, height: 76)

                if viewModel.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 28, height: 28)
                } else {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 62, height: 62)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isConnected)
        .opacity(viewModel.isConnected ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
