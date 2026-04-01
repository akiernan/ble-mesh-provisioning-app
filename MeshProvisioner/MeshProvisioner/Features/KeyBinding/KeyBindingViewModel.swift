import Foundation

@Observable
@MainActor
final class KeyBindingViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var isRunning = false
    var errorMessage: String?

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var stepStates: [KeyBindingStep: KeyBindingStepState] { meshService.keyBindingStepStates }

    var progress: Double {
        let total = KeyBindingStep.allCases.count
        var done = 0.0
        for step in KeyBindingStep.allCases {
            switch stepStates[step] {
            case .completed: done += 1
            case .inProgress: done += 0.5
            default: break
            }
        }
        return done / Double(total)
    }

    var allCompleted: Bool {
        KeyBindingStep.allCases.allSatisfy { stepStates[$0] == .completed }
    }

    func startKeyBinding() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runKeyBinding() }
    }

    private func runKeyBinding() async {
        let nodes = meshService.provisionedNodes
        do {
            try await meshService.performKeyBinding(nodes: nodes)
            try? await Task.sleep(for: .seconds(1))
            router.navigate(to: .groupConfig)
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
        isRunning = false
    }
}
