import SwiftUI

struct KeyBindingView: View {
    @Environment(MeshNetworkService.self) private var meshService
    @Environment(AppRouter.self) private var router
    @State private var viewModel: KeyBindingViewModel?

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
                let vm = KeyBindingViewModel(meshService: meshService, router: router)
                viewModel = vm
                vm.startKeyBinding()
            }
        }
        .navigationBarBackButtonHidden(true)
        .navigationTitle("")
    }

    private func content(vm: KeyBindingViewModel) -> some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(
                                colors: [.orange, .yellow],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 80, height: 80)
                        Image(systemName: "key.fill")
                            .font(.system(size: 32, weight: .medium))
                            .foregroundStyle(.white)
                    }
                    Text("Key Binding")
                        .font(.largeTitle.bold())
                    Text("Configuring secure communication")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 32)

                // Progress
                VStack(spacing: 8) {
                    HStack {
                        Text("Configuration Progress")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                        let completed = KeyBindingStep.allCases.filter {
                            vm.stepStates[$0] == .completed
                        }.count
                        Text("\(completed) of \(KeyBindingStep.allCases.count) steps")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: vm.progress)
                        .tint(
                            LinearGradient(colors: [.orange, .yellow],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                        .scaleEffect(x: 1, y: 1.5)
                }

                // Steps
                VStack(spacing: 12) {
                    ForEach(KeyBindingStep.allCases, id: \.self) { step in
                        VStack(spacing: 6) {
                            KeyBindingStepRow(
                                step: step,
                                state: vm.stepStates[step] ?? .pending
                            )
                            if (step == .distributeKeys || step == .configureModels)
                                && vm.stepStates[step] == .inProgress
                                && !vm.nodeKeyBindingStates.isEmpty {
                                VStack(spacing: 4) {
                                    ForEach(vm.nodeKeyBindingStates) { nodeState in
                                        NodeKeyBindingRow(nodeState: nodeState)
                                    }
                                }
                                .padding(.leading, 20)
                            }
                        }
                    }
                }

                // Security info card
                securityCard

                if let error = vm.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .padding()
                        .background(Color.red.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                if vm.allCompleted {
                    completionBadge
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
    }

    private var securityCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.blue)
                .padding(8)
                .background(Circle().fill(Color.blue.opacity(0.1)))
            VStack(alignment: .leading, spacing: 4) {
                Text("Security Information")
                    .font(.headline)
                    .foregroundStyle(.blue)
                Text("All mesh communication uses AES-CCM encryption with unique application keys. Your devices are secured with industry-standard cryptography.")
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

    private var completionBadge: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.title2)
                .foregroundStyle(.green)
            Text("Key binding completed!")
                .font(.headline)
                .foregroundStyle(.green)
        }
        .padding()
        .background(Color.green.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Node Key Binding Row

private struct NodeKeyBindingRow: View {
    let nodeState: NodeKeyBindingState

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
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(iconColor)
                .frame(width: 24, height: 24)
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .semibold))
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
        case .inProgress: .orange
        case .failed: .red
        case .pending: Color(.systemGray3)
        }
    }

    private var rowBackground: Color {
        switch nodeState.state {
        case .completed: Color.green.opacity(0.05)
        case .inProgress: Color.orange.opacity(0.05)
        case .failed: Color.red.opacity(0.05)
        case .pending: Color(.systemBackground)
        }
    }

    private var borderColor: Color {
        switch nodeState.state {
        case .completed: Color.green.opacity(0.3)
        case .inProgress: Color.orange.opacity(0.5)
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
        case .inProgress: "Sending…"
        case .failed(let msg): msg
        case .pending: "Waiting"
        }
    }
}

// MARK: - Step Row

private struct KeyBindingStepRow: View {
    let step: KeyBindingStep
    let state: KeyBindingStepState

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            stateIcon
            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.headline)
                Text(step.description)
                    .font(.subheadline)
                    .foregroundStyle(descriptionColor)
            }
            Spacer()
        }
        .padding(16)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(rowBorderColor, lineWidth: state == .inProgress ? 2 : 1)
        )
    }

    private var stateIcon: some View {
        ZStack {
            Circle()
                .fill(iconBackground)
                .frame(width: 44, height: 44)
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                
        }
    }

    private var iconName: String {
        switch state {
        case .completed: "checkmark"
        case .inProgress: "arrow.triangle.2.circlepath"
        case .failed: "xmark"
        case .pending:
            switch step {
            case .connectProxy: "antenna.radiowaves.left.and.right"
            case .generateKey: "key"
            case .distributeKeys: "lock"
            case .configureModels: "slider.horizontal.3"
            }
        }
    }

    private var iconBackground: Color {
        switch state {
        case .completed: .green
        case .inProgress: .orange
        case .failed: .red
        case .pending: Color(.systemGray3)
        }
    }

    private var rowBackground: Color {
        switch state {
        case .completed: Color.green.opacity(0.06)
        case .inProgress: Color.orange.opacity(0.06)
        case .failed: Color.red.opacity(0.06)
        case .pending: Color(.systemBackground)
        }
    }

    private var rowBorderColor: Color {
        switch state {
        case .completed: Color.green.opacity(0.4)
        case .inProgress: .orange
        case .failed: Color.red.opacity(0.4)
        case .pending: Color(.separator)
        }
    }

    private var descriptionColor: Color {
        switch state {
        case .completed: .green
        case .inProgress: .orange
        case .failed: .red
        case .pending: .secondary
        }
    }
}
