import Foundation

@Observable
@MainActor
final class SwitchCommissioningViewModel {

    enum State {
        case idle
        case scanning
        case configuring
        case success(EnOceanSwitchConfig)
        case failed(String)
    }

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var state: State = .idle

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    // MARK: - Actions

    func startScan() {
        guard case .idle = state else { return }
        state = .scanning
        Task { await scan() }
    }

    func skip() {
        router.navigate(to: .deviceControl)
    }

    // MARK: - Private

    private func scan() async {
        let reader = EnOceanNFCReader()
        do {
            let config = try await reader.read()
            state = .configuring
            try await meshService.configureEnOceanSwitch(config)
            state = .success(config)
            try? await Task.sleep(for: .seconds(1.5))
            router.navigate(to: .deviceControl)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func retry() {
        state = .idle
    }
}
