import Foundation

@Observable
@MainActor
final class ProvisioningViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var isRunning = false
    var currentIndex = 0
    var completedCount = 0
    var errorMessage: String?

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var devices: [DiscoveredDevice] { meshService.selectedDevicesForProvisioning }

    var totalProgress: Double {
        guard !devices.isEmpty else { return 0 }
        let done = Double(completedCount)
        let current = devices.indices.contains(currentIndex) ? currentDeviceProgress : 0.0
        return (done + current) / Double(devices.count)
    }

    var currentDeviceProgress: Double {
        guard devices.indices.contains(currentIndex) else { return 0 }
        let id = devices[currentIndex].id
        if case .inProgress(let p) = meshService.provisioningStates[id] { return p }
        return 0
    }

    func state(for device: DiscoveredDevice) -> ProvisioningDeviceState {
        meshService.provisioningStates[device.id] ?? .pending
    }

    func startProvisioning() {
        guard !isRunning else { return }
        isRunning = true
        Task { await runProvisioning() }
    }

    private func runProvisioning() async {
        for (index, device) in devices.enumerated() {
            currentIndex = index
            meshService.provisioningStates[device.id] = .inProgress(progress: 0)

            do {
                let node = try await meshService.provisionDevice(device)
                meshService.provisionedNodes.append(node)
                meshService.provisioningStates[device.id] = .completed
                completedCount += 1
            } catch {
                meshService.provisioningStates[device.id] = .failed(error.localizedDescription)
                errorMessage = error.localizedDescription
            }

            try? await Task.sleep(for: .milliseconds(400))
        }

        isRunning = false
        if completedCount > 0 {
            try? await Task.sleep(for: .seconds(1))
            router.navigate(to: .keyBinding)
        }
    }
}
