import SwiftUI

struct DeviceDiagnosticsView: View {

    let unicastAddress: UInt16

    @Environment(MeshNetworkService.self) private var meshService
    @State private var vm: DeviceDiagnosticsViewModel?

    @State private var showSoftResetAlert = false
    @State private var showBootloaderAlert = false
    @State private var showOTAFilePicker = false
    @State private var showOTAAlert = false
    @State private var pendingOTAData: Data?

    var body: some View {
        Group {
            if let vm {
                content(vm: vm)
            } else {
                ProgressView()
            }
        }
        .task {
            if vm == nil {
                let model = DeviceDiagnosticsViewModel(
                    unicastAddress: unicastAddress,
                    meshService: meshService
                )
                vm = model
                await model.connect()
                await model.fetchInfo()
            }
        }
        .onDisappear {
            vm?.disconnect()
        }
    }

    // MARK: - Main Content

    @ViewBuilder
    private func content(vm: DeviceDiagnosticsViewModel) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                connectionStatusBar(vm: vm)
                appInfoCard(vm: vm)
                resetCard(vm: vm)
                otaCard(vm: vm)
            }
            .padding()
        }
        .refreshable {
            vm.disconnect()
            await vm.connect()
            await vm.fetchInfo()
        }
        .navigationTitle(vm.nodeName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(vm.isBusy)
        .fileImporter(
            isPresented: $showOTAFilePicker,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard case .success(let urls) = result,
                  let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            pendingOTAData = try? Data(contentsOf: url)
            if pendingOTAData != nil { showOTAAlert = true }
        }
        .alert("Start OTA Update?", isPresented: $showOTAAlert) {
            Button("Bootloader (faster)") {
                guard let data = pendingOTAData else { return }
                pendingOTAData = nil
                Task { await vm.startOTAViaBootloader(data: data) }
            }
            Button("Direct (slower)") {
                guard let data = pendingOTAData else { return }
                pendingOTAData = nil
                Task { await vm.startOTA(data: data) }
            }
            Button("Cancel", role: .cancel) { pendingOTAData = nil }
        } message: {
            Text("Reboot into bootloader first for a faster upload, or upload directly without rebooting.")
        }
        .alert("Soft Reset", isPresented: $showSoftResetAlert) {
            Button("Reset", role: .destructive) { Task { await vm.softReset() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The device will reboot normally. The app will reconnect to the mesh.")
        }
        .alert("Reset to Bootloader", isPresented: $showBootloaderAlert) {
            Button("Reset", role: .destructive) { Task { await vm.resetToBootloader() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The device will reboot into DFU mode. The mesh connection will not be restored automatically.")
        }
    }

    // MARK: - Connection Status Bar

    private func connectionStatusBar(vm: DeviceDiagnosticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                switch vm.connectionState {
                case .idle:
                    Image(systemName: "circle")
                        .foregroundStyle(.secondary)
                    Text("Not connected")
                        .foregroundStyle(.secondary)
                case .scanning:
                    ProgressView().controlSize(.small)
                    Text("Scanning…")
                        .foregroundStyle(.secondary)
                case .connecting:
                    ProgressView().controlSize(.small)
                    Text("Connecting…")
                        .foregroundStyle(.secondary)
                case .connected:
                    Image(systemName: "circle.fill")
                        .foregroundStyle(.green)
                    Text("Connected via SMP")
                        .foregroundStyle(.primary)
                case .failed(let msg):
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(msg)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    Button("Retry") { Task { await vm.connect() } }
                        .font(.caption)
                }
                Spacer()
            }
            if meshService.proxyNodeName == vm.nodeName {
                HStack(spacing: 4) {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                    Text("Active mesh proxy")
                }
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .font(.subheadline)
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - App Info Card

    private func appInfoCard(vm: DeviceDiagnosticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(title: "App Info", systemImage: "info.circle") {
                Button {
                    Task { await vm.fetchInfo() }
                } label: {
                    if case .fetchingInfo = vm.currentOperation {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(vm.isBusy || !vm.isConnected)
            }

            Divider()

            if let info = vm.appInfo {
                infoRow(label: "Project", value: info.project)
                infoRow(label: "Version", value: info.version)
                infoRow(label: "IDF", value: info.idfVersion)
                infoRow(label: "Chip", value: info.chip)
                infoRow(label: "Built", value: info.buildDate)
            } else {
                Text(vm.isConnected ? "Loading…" : "Connecting…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }

            if !vm.imageSlots.isEmpty {
                Divider()
                ForEach(vm.imageSlots) { slot in
                    imageSlotRow(slot)
                }
            }
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Reset Card

    private func resetCard(vm: DeviceDiagnosticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(title: "Reset", systemImage: "power") { EmptyView() }
            Divider()
            HStack(spacing: 12) {
                Button("Soft Reset") { showSoftResetAlert = true }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .disabled(!vm.isConnected || vm.isBusy)
                Button("Reset to Bootloader") { showBootloaderAlert = true }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(!vm.isConnected || vm.isBusy)
            }
            .padding(16)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - OTA Card

    private func otaCard(vm: DeviceDiagnosticsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader(title: "OTA Update", systemImage: "arrow.down.circle") { EmptyView() }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if case .resettingToBootloader = vm.currentOperation {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Rebooting into bootloader…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else if case .uploading(let progress) = vm.currentOperation {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress)
                            .tint(.blue)
                        Text("\(Int(progress * 100))%  —  direct BLE connection")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if case .reconnecting = vm.currentOperation {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reconnecting to mesh…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Button {
                        showOTAFilePicker = true
                    } label: {
                        Label("Choose Firmware File (.bin)", systemImage: "doc.badge.arrow.up")
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.isBusy)
                    Text("The mesh proxy will be disconnected during upload.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let error = vm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(16)
        }
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Reusable Row Components

    @ViewBuilder
    private func cardHeader(title: String, systemImage: String,
                            @ViewBuilder trailing: () -> some View) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .font(.headline)
            Spacer()
            trailing()
        }
        .padding(16)
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.subheadline.monospacedDigit())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func imageSlotRow(_ slot: ImageSlotInfo) -> some View {
        HStack {
            Text("Slot \(slot.slot)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(slot.version)
                .font(.subheadline.monospacedDigit())
            Spacer()
            if slot.active {
                slotTag("active", color: .green)
            } else if slot.pending {
                slotTag("pending", color: .orange)
            } else if slot.confirmed {
                slotTag("confirmed", color: .blue)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func slotTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }
}

// MARK: - ViewModel Convenience

private extension DeviceDiagnosticsViewModel {
    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var isBusy: Bool {
        if case .none = currentOperation { return false }
        return true
    }
}
