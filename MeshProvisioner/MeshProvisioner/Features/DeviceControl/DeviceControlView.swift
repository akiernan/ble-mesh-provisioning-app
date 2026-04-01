import SwiftUI

struct DeviceControlView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: DeviceControlViewModel?
    @State private var showDevices = false

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
                viewModel = DeviceControlViewModel(meshService: meshService, router: router)
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
    }

    private func content(vm: DeviceControlViewModel) -> some View {
        VStack(spacing: 0) {
            // Dark header
            header(vm: vm)

            ScrollView {
                VStack(spacing: 24) {
                    // Power toggle
                    powerSection(vm: vm)

                    // Sliders (only active when on)
                    if let group = vm.group {
                        slidersSection(vm: vm, group: group)
                            .opacity(group.isOn ? 1 : 0.4)
                            .disabled(!group.isOn)
                    }

                    // Individual devices
                    devicesSection(vm: vm)

                    // Mesh info card
                    meshInfoCard(vm: vm)

                    if let error = vm.errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                }
                .padding(24)
            }
        }
    }

    // MARK: - Header

    private func header(vm: DeviceControlViewModel) -> some View {
        ZStack {
            LinearGradient(
                colors: [Color(white: 0.15), Color(white: 0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 48, height: 48)
                    Image(systemName: "lightbulb.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.group?.name ?? "Lights")
                        .font(.title2.bold())
                        .foregroundStyle(.white)
                    Text("\(vm.deviceCount) device\(vm.deviceCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                Spacer()
                Button {
                    vm.restart()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.body)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(Color.white.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
        }
    }

    // MARK: - Power

    private func powerSection(vm: DeviceControlViewModel) -> some View {
        HStack {
            Label("Power", systemImage: "power")
                .font(.headline)
            Spacer()
            if let group = vm.group {
                Toggle("", isOn: Binding(
                    get: { group.isOn },
                    set: { _ in vm.togglePower() }
                ))
                .toggleStyle(CTLToggleStyle())
            }
        }
        .padding(20)
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }

    // MARK: - Sliders

    private func slidersSection(vm: DeviceControlViewModel, group: MeshGroupConfig) -> some View {
        VStack(spacing: 24) {
            // Brightness
            VStack(spacing: 12) {
                HStack {
                    Label("Brightness", systemImage: "sun.max.fill")
                        .font(.headline)
                    Spacer()
                    Text("\(Int(group.lightness * 100))%")
                        .font(.title3.bold())
                        .monospacedDigit()
                }
                Slider(
                    value: Binding(
                        get: { group.lightness },
                        set: { vm.setLightness($0) }
                    ),
                    in: 0...1,
                    step: 0.01
                )
                .tint(
                    LinearGradient(colors: [.blue, .cyan],
                                   startPoint: .leading, endPoint: .trailing)
                )
                HStack {
                    Text("0%").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("50%").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("100%").font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            // Color temperature
            VStack(spacing: 12) {
                HStack {
                    Label("Color Temperature", systemImage: "thermometer.medium")
                        .font(.headline)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(group.temperature)K")
                            .font(.title3.bold())
                            .monospacedDigit()
                        Text(group.temperatureLabel())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                temperatureSlider(vm: vm, group: group)
                HStack {
                    Text("2000K\nWarm").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    Spacer()
                    Text("5000K").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("8000K\nCool").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func temperatureSlider(vm: DeviceControlViewModel, group: MeshGroupConfig) -> some View {
        let minTemp = Double(MeshGroupConfig.temperatureMin)
        let maxTemp = Double(MeshGroupConfig.temperatureMax)
        return ZStack {
            // Gradient track
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(
                    stops: [
                        .init(color: Color(red: 1.0, green: 0.55, blue: 0.26), location: 0),
                        .init(color: Color(red: 1.0, green: 0.85, blue: 0.0), location: 0.2),
                        .init(color: .white, location: 0.5),
                        .init(color: Color(red: 0.7, green: 0.85, blue: 1.0), location: 0.75),
                        .init(color: Color(red: 0.29, green: 0.56, blue: 0.89), location: 1.0)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(height: 12)
                .padding(.horizontal, 12)
            Slider(
                value: Binding(
                    get: { Double(group.temperature) },
                    set: { vm.setTemperature($0) }
                ),
                in: minTemp...maxTemp,
                step: 100
            )
            .tint(.clear)
        }
        .frame(height: 32)
    }

    // MARK: - Devices

    private func devicesSection(vm: DeviceControlViewModel) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.3)) {
                    showDevices.toggle()
                }
            } label: {
                HStack {
                    Label("Individual Devices", systemImage: "slider.horizontal.3")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Spacer()
                    Image(systemName: showDevices ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .padding(16)
            }
            .buttonStyle(.plain)
            .background(Color(.systemBackground))
            .clipShape(showDevices
                       ? RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .path(in: CGRect(x: 0, y: 0, width: 400, height: 52))
                       : RoundedRectangle(cornerRadius: 16).path(in: CGRect(x: 0, y: 0, width: 400, height: 52)))

            if showDevices {
                VStack(spacing: 8) {
                    ForEach(Array(vm.deviceNames.enumerated()), id: \.0) { _, name in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(vm.group?.isOn == true ? Color.green : Color(.systemGray3))
                                .frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(name).font(.subheadline).fontWeight(.medium)
                            }
                            Spacer()
                            Text("Connected")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.green.opacity(0.1))
                                .clipShape(Capsule())
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .background(Color(.systemBackground))
                .clipShape(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color(.separator), lineWidth: 1)
        )
    }

    // MARK: - Mesh info card

    private func meshInfoCard(vm: DeviceControlViewModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.blue)
                    .frame(width: 28, height: 28)
                Text("i")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Mesh Network \(vm.isConnected ? "Active" : "Connecting...")")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Text("All devices in this group are connected via BLE mesh. Changes are broadcast to all devices simultaneously for synchronized control.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(Color.blue.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.blue.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - CTL Toggle Style

private struct CTLToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(.spring(response: 0.25)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack {
                Capsule()
                    .fill(configuration.isOn
                          ? LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                          : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray4)],
                                           startPoint: .leading, endPoint: .trailing))
                    .frame(width: 80, height: 40)
                Circle()
                    .fill(.white)
                    .shadow(radius: 3)
                    .frame(width: 32, height: 32)
                    .offset(x: configuration.isOn ? 18 : -18)
            }
        }
        .buttonStyle(.plain)
    }
}
