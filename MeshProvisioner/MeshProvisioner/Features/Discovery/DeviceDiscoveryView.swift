import SwiftUI

struct DeviceDiscoveryView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: DeviceDiscoveryViewModel?

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
                viewModel = DeviceDiscoveryViewModel(meshService: meshService, router: router)
            }
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
    }

    @ViewBuilder
    private func content(vm: DeviceDiscoveryViewModel) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 32) {
                    // Header
                    VStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(LinearGradient(
                                    colors: [.blue, .cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ))
                                .frame(width: 80, height: 80)
                            Image(systemName: "wave.3.right")
                                .font(.system(size: 32, weight: .medium))
                                .foregroundStyle(.white)
                        }
                        Text("Discover Devices")
                            .font(.largeTitle.bold())
                        Text("Scan for nearby BLE mesh devices to add to your network")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 32)

                    if !vm.bluetoothReady {
                        bluetoothUnavailableView
                    } else if !vm.isScanning && vm.discoveredDevices.isEmpty {
                        scanButton(vm: vm)
                    } else {
                        deviceList(vm: vm)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 120)
            }
            .onChange(of: vm.discoveredDevices.count) {
                vm.autoSelectNewDevices()
            }

            footer(vm: vm)
        }
    }

    private var bluetoothUnavailableView: some View {
        ContentUnavailableView(
            "Bluetooth Unavailable",
            systemImage: "xmark.circle",
            description: Text("Please enable Bluetooth to scan for mesh devices.")
        )
    }

    private func scanButton(vm: DeviceDiscoveryViewModel) -> some View {
        Button {
            vm.startScanning()
        } label: {
            Text("Start Scanning")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [.blue, .cyan],
                                   startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .shadow(color: .blue.opacity(0.3), radius: 8, y: 4)
    }

    private func deviceList(vm: DeviceDiscoveryViewModel) -> some View {
        VStack(spacing: 16) {
            HStack {
                Text("Found \(vm.discoveredDevices.count) device\(vm.discoveredDevices.count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
            }

            ForEach(vm.discoveredDevices) { device in
                DeviceRow(
                    device: device,
                    isSelected: vm.isSelected(device)
                ) {
                    vm.toggle(device)
                }
                .transition(.asymmetric(
                    insertion: .push(from: .bottom),
                    removal: .opacity
                ))
            }
        }
        .animation(.spring(response: 0.4), value: vm.discoveredDevices.count)
    }

    private func footer(vm: DeviceDiscoveryViewModel) -> some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                vm.continueToProvisioning()
            } label: {
                Text("Continue with \(vm.selectedDevices.count) device\(vm.selectedDevices.count == 1 ? "" : "s")")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        vm.selectedDevices.count > 0
                        ? LinearGradient(colors: [.blue, .cyan],
                                         startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray4)],
                                         startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(vm.selectedDevices.count == 0)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial)
        }
    }
}

// MARK: - Device Row

private struct DeviceRow: View {
    let device: DiscoveredDevice
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                signalIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(device.signalStrength.label)
                        Text("•")
                        Text("\(device.rssi) dBm")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                checkmark
            }
            .padding(16)
            .background(isSelected ? Color.blue.opacity(0.08) : Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(isSelected ? Color.blue : Color(.separator), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.2), value: isSelected)
    }

    private var signalIcon: some View {
        Image(systemName: "wave.3.right")
            .font(.title3)
            .foregroundStyle(signalColor)
    }

    private var signalColor: Color {
        switch device.signalStrength {
        case .excellent: .green
        case .good: .blue
        case .fair: .yellow
        case .weak: .red
        }
    }

    private var checkmark: some View {
        ZStack {
            Circle()
                .fill(isSelected ? Color.blue : Color(.systemGray5))
                .frame(width: 28, height: 28)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }
}
