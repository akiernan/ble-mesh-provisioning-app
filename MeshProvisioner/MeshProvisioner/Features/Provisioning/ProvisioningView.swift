import SwiftUI

struct ProvisioningView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: ProvisioningViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                content(vm: vm)
            } else {
                ProgressView()
            }
        }
        .task {
            if viewModel == nil {
                let vm = ProvisioningViewModel(meshService: meshService, router: router)
                viewModel = vm
                vm.startProvisioning()
            }
        }
        .navigationBarBackButtonHidden(viewModel?.isRunning ?? true)
        .navigationTitle("Provisioning")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel?.isRunning == true {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { viewModel?.cancelAndReturn() }
                }
            }
        }
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
                        .progressViewStyle(GradientProgressStyle(
                            gradient: LinearGradient(colors: [.purple, .pink],
                                                     startPoint: .leading, endPoint: .trailing)
                        ))
                        .accessibilityLabel("Overall progress")
                        .accessibilityValue("\(vm.completedCount) of \(vm.devices.count) complete")
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

            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .sensoryFeedback(.success, trigger: vm.completedCount == vm.devices.count && !vm.devices.isEmpty)
        .sensoryFeedback(.error, trigger: vm.errorMessage)
        .alert("Provisioning Failed", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }
}

// MARK: - Device Row

private struct ProvisioningDeviceRow: View {
    let device: DiscoveredDevice
    let state: ProvisioningDeviceState
    @ScaledMetric private var iconSize: CGFloat = 44

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        switch state {
        case .pending:    return "\(device.name), waiting"
        case .connecting: return "\(device.name), connecting"
        case .inProgress: return "\(device.name), provisioning, \(Int(currentDeviceProgressValue * 100)) percent"
        case .completed:  return "\(device.name), provisioned"
        case .failed(let msg): return "\(device.name), failed: \(msg)"
        }
    }

    private var currentDeviceProgressValue: Double {
        if case .inProgress(let p) = state { return p }
        return 0
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
                .frame(width: iconSize, height: iconSize)
            Image(systemName: iconName)
                .font(.system(size: iconSize * 0.4, weight: .medium))
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
