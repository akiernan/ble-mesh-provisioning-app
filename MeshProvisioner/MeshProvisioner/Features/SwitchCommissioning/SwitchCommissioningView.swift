import SwiftUI

struct SwitchCommissioningView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: SwitchCommissioningViewModel?
    @State private var showQRScanner = false

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
                    .fullScreenCover(isPresented: $showQRScanner) {
                        QRScannerView(
                            onResult: { string in
                                showQRScanner = false
                                vm.handleQRCode(string)
                            },
                            onCancel: {
                                showQRScanner = false
                            }
                        )
                        .ignoresSafeArea()
                    }
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                viewModel = SwitchCommissioningViewModel(meshService: meshService, router: router)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("Commission Switch")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if let vm = viewModel, canSkip(vm.state) {
                    Button("Skip") { vm.skip() }
                }
            }
        }
    }

    private func canSkip(_ state: SwitchCommissioningViewModel.State) -> Bool {
        switch state {
        case .idle, .failed: return true
        default: return false
        }
    }

    @ViewBuilder
    private func content(vm: SwitchCommissioningViewModel) -> some View {
        VStack(spacing: 40) {
            Spacer()
            switch vm.state {
            case .idle:
                idleContent(vm: vm)
            case .scanningNFC:
                scanningNFCContent
            case .configuring:
                configuringContent
            case .success(let config):
                successContent(config: config)
            case .failed(let message):
                failedContent(message: message, vm: vm)
            }
            Spacer()
        }
        .padding(32)
        .multilineTextAlignment(.center)
    }

    // MARK: - States

    private func idleContent(vm: SwitchCommissioningViewModel) -> some View {
        VStack(spacing: 32) {
            ZStack {
                Circle()
                    .fill(LinearGradient(
                        colors: [Color.blue.opacity(0.15), Color.teal.opacity(0.15)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 140, height: 140)
                Image(systemName: "switch.2")
                    .font(.system(size: 56))
                    .foregroundStyle(
                        LinearGradient(colors: [.blue, .teal], startPoint: .leading, endPoint: .trailing)
                    )
            }
            VStack(spacing: 12) {
                Text("Commission Switch")
                    .font(.largeTitle.bold())
                Text("Scan the QR code on the switch label, or hold the switch near your iPhone to read via NFC.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 12) {
                Button {
                    showQRScanner = true
                } label: {
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [.blue, .teal], startPoint: .leading, endPoint: .trailing)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)

                Button {
                    vm.startNFCScan()
                } label: {
                    Label("Scan via NFC", systemImage: "wave.3.right")
                        .font(.headline)
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.blue.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private var scanningNFCContent: some View {
        VStack(spacing: 24) {
            Image(systemName: "wave.3.right.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(
                    LinearGradient(colors: [.blue, .teal], startPoint: .leading, endPoint: .trailing)
                )
                .symbolEffect(.pulse)
            Text("Waiting for switch…")
                .font(.title2.bold())
            Text("The system NFC panel is active. Hold your switch near the top of the phone.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var configuringContent: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)
                .tint(.blue)
            Text("Configuring switch…")
                .font(.title2.bold())
            Text("Sending credentials to the mesh network.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private func successContent(config: EnOceanSwitchConfig) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 100, height: 100)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
            }
            VStack(spacing: 8) {
                Text("Switch Ready")
                    .font(.title2.bold())
                Text(config.addressString)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func failedContent(message: String, vm: SwitchCommissioningViewModel) -> some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.12))
                    .frame(width: 100, height: 100)
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.red)
            }
            VStack(spacing: 8) {
                Text("Failed to Read Switch")
                    .font(.title2.bold())
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            Button {
                vm.retry()
            } label: {
                Text("Try Again")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }
}
