import SwiftUI
import UIKit

struct DeviceControlView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: DeviceControlViewModel?
    @State private var showDevices = false
    @State private var showResetConfirm = false

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
                let vm = DeviceControlViewModel(meshService: meshService, router: router)
                viewModel = vm
                vm.connectIfNeeded()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle(viewModel?.group?.name ?? "Lights")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .navigationBar)
        .overlay {
            if let vm = viewModel, vm.isResetting {
                resetProgressOverlay(vm: vm)
            }
        }
        .confirmationDialog("Reset Mesh Network?", isPresented: $showResetConfirm, titleVisibility: .visible) {
            Button("Reset All Devices", role: .destructive) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                viewModel?.restart()
            }
            Button("Reset Local Only", role: .destructive) {
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                viewModel?.resetLocalOnly()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Reset all devices and local state, or reset local state only if devices have already been reset.")
        }
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
                        let slidersActive = group.isOn && group.lightness > 0
                        slidersSection(vm: vm, group: group)
                            .opacity(slidersActive ? 1 : 0.4)
                            .disabled(!slidersActive)
                    }

                    // Individual devices
                    devicesSection(vm: vm)
                }
                .padding(24)
            }

        }
        .sensoryFeedback(.error, trigger: vm.errorMessage)
        .alert("Error", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Header

    private func header(vm: DeviceControlViewModel) -> some View {
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
                let isActive = !meshService.isConnectedToProxy || meshService.isFetchingState
                HStack(spacing: 6) {
                    Text("\(vm.deviceCount) device\(vm.deviceCount == 1 ? "" : "s")")
                        .font(.subheadline)
                        .foregroundStyle(Color.white.opacity(0.7))
                    ProgressView()
                        .tint(Color.white.opacity(0.7))
                        .scaleEffect(0.7)
                        .opacity(isActive ? 1 : 0)
                }
                .animation(.easeInOut(duration: 0.2), value: isActive)
            }
            Spacer()
            Button {
                showResetConfirm = true
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.white.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .accessibilityLabel("Reset mesh network")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .background(
            LinearGradient(
                colors: [Color(white: 0.15), Color(white: 0.08)],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
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
                .accessibilityLabel("Power")
                .accessibilityValue(group.isOn ? "On" : "Off")
                .accessibilityHint("Double tap to turn \(group.isOn ? "off" : "on")")
                .sensoryFeedback(.impact, trigger: group.isOn)
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
                        .opacity(group.isOn && group.lightness > 0 ? 1 : 0)
                }
                brightnessSlider(vm: vm, group: group)
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
                    Text("\(group.temperatureRangeMin)K\nWarm").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    Spacer()
                    Text("\((group.temperatureRangeMin + group.temperatureRangeMax) / 2)K").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(group.temperatureRangeMax)K\nCool").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
            }
        }
        .padding(20)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func brightnessSlider(vm: DeviceControlViewModel, group: MeshGroupConfig) -> some View {
        let thumbDiameter: CGFloat = 28
        let thumbRadius = thumbDiameter / 2
        return ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(LinearGradient(
                    colors: [Color(white: 0.12), Color(white: 0.55), Color(white: 1.0)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .frame(height: 12)
                .padding(.horizontal, 12)
            Slider(
                value: Binding(
                    get: { group.lightness },
                    set: { vm.setLightness($0) }
                ),
                in: 0...1,
                step: 0.01
            )
            .tint(.clear)
            .accessibilityLabel("Brightness")
            .accessibilityValue("\(Int(group.lightness * 100)) percent")
            if group.isOn && group.lightness > 0 {
                GeometryReader { geo in
                    let x = thumbRadius + (geo.size.width - thumbDiameter) * group.lightness
                    Circle()
                        .stroke(Color.primary.opacity(0.25), lineWidth: 1.5)
                        .frame(width: thumbDiameter, height: thumbDiameter)
                        .position(x: x, y: geo.size.height / 2)
                }
            }
        }
        .frame(height: 32)
    }

    /// Full CCT ramp covering 800–20000 K. startPoint/endPoint are computed
    /// so only the device's supported temperature range is visible in the track.
    private func cctGradient(for group: MeshGroupConfig) -> LinearGradient {
        let fullMin = 800.0, fullMax = 20000.0
        let normMin = (Double(group.temperatureRangeMin) - fullMin) / (fullMax - fullMin)
        let normMax = (Double(group.temperatureRangeMax) - fullMin) / (fullMax - fullMin)
        let span = max(normMax - normMin, 0.001)
        // Offset startPoint/endPoint so the gradient is "zoomed in" to [normMin, normMax]
        let startX = -normMin / span
        let endX   = (1 - normMin) / span
        return LinearGradient(
            stops: [
                .init(color: Color(red: 1.0, green: 0.55, blue: 0.26), location: 0),
                .init(color: Color(red: 1.0, green: 0.85, blue: 0.0),  location: 0.2),
                .init(color: Color(white: 0.88),                        location: 0.5),
                .init(color: Color(red: 0.7,  green: 0.85, blue: 1.0), location: 0.75),
                .init(color: Color(red: 0.29, green: 0.56, blue: 0.89), location: 1.0)
            ],
            startPoint: UnitPoint(x: startX, y: 0.5),
            endPoint:   UnitPoint(x: endX,   y: 0.5)
        )
    }

    private func temperatureSlider(vm: DeviceControlViewModel, group: MeshGroupConfig) -> some View {
        let minTemp = Double(group.temperatureRangeMin)
        let maxTemp = Double(group.temperatureRangeMax)
        let thumbDiameter: CGFloat = 28
        let thumbRadius = thumbDiameter / 2
        return ZStack {
            // Gradient track — sliced to device's discovered CCT range
            RoundedRectangle(cornerRadius: 4)
                .fill(cctGradient(for: group))
                .frame(height: 12)
                .padding(.horizontal, 12)
            Slider(
                value: Binding(
                    get: { Double(group.temperature) },
                    set: { vm.setTemperature($0) }
                ),
                in: minTemp...maxTemp,
                step: 1
            )
            .tint(.clear)
            .accessibilityLabel("Color temperature")
            .accessibilityValue("\(group.temperature) Kelvin, \(group.temperatureLabel())")
            // Outline ring on the thumb so it stays visible at the near-white midpoint
            GeometryReader { geo in
                let fraction = (Double(group.temperature) - minTemp) / max(maxTemp - minTemp, 1)
                let x = thumbRadius + (geo.size.width - thumbDiameter) * fraction
                Circle()
                    .stroke(Color.primary.opacity(0.25), lineWidth: 1.5)
                    .frame(width: thumbDiameter, height: thumbDiameter)
                    .position(x: x, y: geo.size.height / 2)
            }
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
                    ForEach(Array(vm.provisionedDevices.enumerated()), id: \.0) { _, device in
                        Button {
                            router.navigate(to: .deviceDiagnostics(device.unicastAddress))
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: vm.group?.isOn == true ? "circle.fill" : "circle")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(vm.group?.isOn == true ? Color.green : Color(.systemGray3))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(device.name).font(.subheadline).fontWeight(.medium)
                                }
                                if meshService.proxyNodeName == device.name {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
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
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(device.name), Connected, \(vm.group?.isOn == true ? "On" : "Off")")
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

    // MARK: - Reset Progress Overlay

    private func resetProgressOverlay(vm: DeviceControlViewModel) -> some View {
        ZStack {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
            VStack(spacing: 20) {
                ProgressView(value: vm.resetTotal > 0 ? Double(vm.resetCompleted) / Double(vm.resetTotal) : 0)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(width: 200)
                ProgressView()
                    .tint(.white)
                VStack(spacing: 6) {
                    Text("Resetting Devices")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("\(vm.resetCompleted) of \(vm.resetTotal)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 20))
        }
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
                    .frame(width: 80, height: 44)
                Circle()
                    .fill(.white)
                    .shadow(radius: 3)
                    .frame(width: 36, height: 36)
                    .offset(x: configuration.isOn ? 18 : -18)
            }
        }
        .buttonStyle(.plain)
    }
}
