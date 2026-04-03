import SwiftUI

struct GroupConfigView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: GroupConfigViewModel?

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
                viewModel = GroupConfigViewModel(meshService: meshService, router: router)
            }
        }
        .navigationBarBackButtonHidden(viewModel?.isConfiguring ?? false)
        .navigationTitle("Group Configuration")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(vm: GroupConfigViewModel) -> some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [.green, .teal],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 80, height: 80)
                        Image(systemName: "person.3.fill")
                            .font(.system(size: 28, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Text("Group Configuration")
                        .font(.largeTitle.bold())
                    Text("Create a group to control all devices together")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 32)

                if vm.isConfiguring {
                    configuringView(vm: vm)
                } else {
                    setupView(vm: vm)
                }

            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .sensoryFeedback(.error, trigger: vm.errorMessage)
        .alert("Group Configuration Failed", isPresented: Binding(
            get: { vm.errorMessage != nil },
            set: { if !$0 { vm.errorMessage = nil } }
        )) {
            Button("OK") { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    // MARK: - Setup form

    private func setupView(vm: GroupConfigViewModel) -> some View {
        VStack(spacing: 24) {
            // Devices in group
            VStack(alignment: .leading, spacing: 12) {
                Label("Devices in Group", systemImage: "person.3")
                    .font(.headline)
                VStack(spacing: 8) {
                    ForEach(vm.devices) { device in
                        HStack {
                            Text(device.name)
                                .font(.subheadline)
                            Spacer()
                            Label("Ready", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                        }
                        .padding(12)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))

            // Room name input
            VStack(alignment: .leading, spacing: 8) {
                Text("Room Name")
                    .font(.headline)
                TextField("Enter room name", text: Binding(
                    get: { vm.roomName },
                    set: { vm.roomName = $0 }
                ))
                .padding(12)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color(.separator), lineWidth: 1)
                )
            }

            // Quick select
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Select")
                    .font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], spacing: 8) {
                    ForEach(vm.suggestedRooms, id: \.self) { room in
                        Button {
                            vm.roomName = room
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "house")
                                    .font(.body)
                                Text(room)
                                    .font(.caption)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity)
                            .background(vm.roomName == room
                                        ? Color.teal.opacity(0.15)
                                        : Color(.systemBackground))
                            .foregroundStyle(vm.roomName == room ? .teal : .primary)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(vm.roomName == room ? Color.teal : Color(.separator),
                                            lineWidth: vm.roomName == room ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            // Create button
            Button {
                vm.createGroup()
            } label: {
                Text("Create Group")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        vm.roomName.trimmingCharacters(in: .whitespaces).isEmpty
                        ? LinearGradient(colors: [Color(.systemGray4), Color(.systemGray4)],
                                         startPoint: .leading, endPoint: .trailing)
                        : LinearGradient(colors: [.green, .teal],
                                         startPoint: .leading, endPoint: .trailing)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(vm.roomName.trimmingCharacters(in: .whitespaces).isEmpty)
            .shadow(color: .green.opacity(0.3), radius: 8, y: 4)
        }
    }

    // MARK: - Configuring state

    private func configuringView(vm: GroupConfigViewModel) -> some View {
        VStack(spacing: 24) {
            // Overall progress bar
            VStack(spacing: 8) {
                HStack {
                    Text("Setup Progress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    let completed = vm.nodeGroupConfigStates.filter { $0.state == .completed }.count
                    let total = vm.nodeGroupConfigStates.count
                    Text(total > 0 ? "\(completed) of \(total) devices" : "\(Int(vm.configProgress * 100))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: vm.configProgress)
                    .progressViewStyle(GradientProgressStyle(
                        gradient: LinearGradient(colors: [.green, .teal],
                                                 startPoint: .leading, endPoint: .trailing)
                    ))
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue({
                        let completed = vm.nodeGroupConfigStates.filter { $0.state == .completed }.count
                        let total = vm.nodeGroupConfigStates.count
                        return total > 0
                            ? "\(completed) of \(total) devices complete"
                            : "\(Int(vm.configProgress * 100)) percent"
                    }())
            }

            // Per-device rows
            if !vm.nodeGroupConfigStates.isEmpty {
                VStack(spacing: 6) {
                    ForEach(vm.nodeGroupConfigStates) { nodeState in
                        NodeGroupConfigRow(nodeState: nodeState)
                    }
                }
            }
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Node Group Config Row

private struct NodeGroupConfigRow: View {
    let nodeState: NodeKeyBindingState
    @ScaledMetric private var iconSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 10) {
            stateIcon
            Text(nodeState.name)
                .font(.subheadline)
            Spacer()
            stateLabel
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(borderColor, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(nodeState.name): \(stateName)")
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(iconColor)
                .frame(width: iconSize, height: iconSize)
            Image(systemName: iconName)
                .font(.system(size: iconSize * 0.42, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private var iconName: String {
        switch nodeState.state {
        case .completed: "checkmark"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .failed: "xmark"
        case .pending: "clock"
        }
    }

    private var iconColor: Color {
        switch nodeState.state {
        case .completed: .green
        case .inProgress: .teal
        case .failed: .red
        case .pending: Color(.systemGray3)
        }
    }

    private var rowBackground: Color {
        switch nodeState.state {
        case .completed: Color.green.opacity(0.05)
        case .inProgress: Color.teal.opacity(0.05)
        case .failed: Color.red.opacity(0.05)
        case .pending: Color(.systemBackground)
        }
    }

    private var borderColor: Color {
        switch nodeState.state {
        case .completed: Color.green.opacity(0.3)
        case .inProgress: Color.teal.opacity(0.5)
        case .failed: Color.red.opacity(0.3)
        case .pending: Color(.separator)
        }
    }

    private var stateLabel: some View {
        Text(stateName)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(iconColor)
    }

    private var stateName: String {
        switch nodeState.state {
        case .completed: "Done"
        case .inProgress: "Configuring…"
        case .failed(let msg): msg
        case .pending: "Waiting"
        }
    }
}
