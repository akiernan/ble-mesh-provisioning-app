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
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
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
                LazyVGrid(columns: Array(repeating: .init(.flexible()), count: 3), spacing: 8) {
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
            ProgressView()
                .scaleEffect(1.5)
                .tint(.teal)
            Text("Configuring group bindings...")
                .font(.headline)
            Text("Setting up \"\(vm.roomName)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                HStack {
                    Text("Setup Progress")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(vm.configProgress * 100))%")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ProgressView(value: vm.configProgress)
                    .tint(
                        LinearGradient(colors: [.green, .teal],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .scaleEffect(x: 1, y: 1.5)
            }

            if !vm.configStatus.isEmpty {
                Text(vm.configStatus)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.default, value: vm.configStatus)
            }
        }
        .padding(24)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
