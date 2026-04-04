import Foundation

@Observable
@MainActor
final class SwitchCommissioningViewModel {

    enum State {
        case idle
        case scanningNFC
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

    func startNFCScan() {
        guard case .idle = state else { return }
        state = .scanningNFC
        Task { await scanNFC() }
    }

    func handleQRCode(_ string: String) {
        state = .configuring
        Task { await configureFrom(qrString: string) }
    }

    func skip() {
        router.navigate(to: .deviceControl)
    }

    func retry() {
        state = .idle
    }

    // MARK: - Private

    private func scanNFC() async {
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

    private func configureFrom(qrString: String) async {
        do {
            let config = try EnOceanQRParser.parse(qrString)
            try await meshService.configureEnOceanSwitch(config)
            state = .success(config)
            try? await Task.sleep(for: .seconds(1.5))
            router.navigate(to: .deviceControl)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
