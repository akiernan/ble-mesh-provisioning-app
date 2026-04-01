import SwiftUI

struct ProvisioningView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ProvisioningViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            }
        }
        .onAppear {
            if viewModel == nil {
                let vm = ProvisioningViewModel(meshService: meshService, router: router)
                viewModel = vm
                vm.startProvisioning()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
    }

    private func content(vm: ProvisioningViewModel) -> some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [.purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 80, height: 80)
                        Image(systemName: "shield.lefthalf.filled")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Text("Provisioning")
                        .font(.largeTitle.bold())
                    Text("Adding devices to the mesh network securely")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                // Overall progress
                VStack(spacing: 8) {
                    HStack {
                        Text("Overall Progress")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(vm.completedCount) of \(vm.devices.count) complete")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: vm.totalProgress)
                        .tint(
                            LinearGradient(colors: [.purple, .pink],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .scaleEffect(x: 1, y: 1.5)
                }

                // Device list
                VStack(spacing: 12) {
                    ForEach(vm.devices) { device in
                        ProvisioningDeviceRow(
                            device: device,
                            state: vm.state(for: device)
                        )
                    }
                }

                // Success message
                if vm.completedCount == vm.devices.count && !vm.devices.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.green)
                        Text("All devices provisioned successfully!")
                            .font(.headline)
                            .foregroundStyle(.green)
                    }
                    .padding()
                    .background(Color.green.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if let error = vm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }
}

// MARK: - Device Row

private struct ProvisioningDeviceRow: View {
    let device: DiscoveredDevice
    let state: ProvisioningDeviceState

    var body: some View {
        HStack(spacing: 16) {
            stateIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                stateLabel
            }
            Spacer()
            if case .inProgress(let p) = state {
                Text("\(Int(p * 100))%")
                    .font(.headline)
                    .foregroundStyle(.purple)
                    .monospacedDigit()
            }
        }
        .padding(16)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(rowBorderColor, lineWidth: 2)
        )
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
                .frame(width: 44, height: 44)
            Image(systemName: iconName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.white)
                
        }
    }

    private var stateLabel: some View {
        Group {
            switch state {
            case .pending:
                Text("Waiting").foregroundStyle(.secondary)
            case .connecting:
                Text("Connecting...").foregroundStyle(.purple)
            case .inProgress:
                Text("Provisioning...").foregroundStyle(.purple)
            case .completed:
                Text("Provisioned").foregroundStyle(.green)
            case .failed(let msg):
                Text("Failed: \(msg)").foregroundStyle(.red)
            }
        }
        .font(.subheadline)
    }

    private var isAnimating: Bool {
        if case .inProgress = state { return true }
        if case .connecting = state { return true }
        return false
    }

    private var iconName: String {
        switch state {
        case .pending: "network"
        case .connecting, .inProgress: "arrow.triangle.2.circlepath"
        case .completed: "checkmark"
        case .failed: "xmark"
        }
    }

    private var iconBackground: Color {
        switch state {
        case .pending: Color(.systemGray3)
        case .connecting, .inProgress: .purple
        case .completed: .green
        case .failed: .red
        }
    }

    private var rowBackground: Color {
        switch state {
        case .completed: Color.green.opacity(0.06)
        case .inProgress, .connecting: Color.purple.opacity(0.06)
        case .failed: Color.red.opacity(0.06)
        default: Color(.systemBackground)
        }
    }

    private var rowBorderColor: Color {
        switch state {
        case .completed: Color.green.opacity(0.4)
        case .inProgress, .connecting: .purple
        case .failed: Color.red.opacity(0.4)
        default: Color(.separator)
        }
    }
}
