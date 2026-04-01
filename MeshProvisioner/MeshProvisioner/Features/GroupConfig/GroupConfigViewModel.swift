import Foundation

@Observable
@MainActor
final class GroupConfigViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var roomName = "Living Room"
    var isConfiguring = false
    var configProgress: Double = 0
    var errorMessage: String?

    let suggestedRooms = ["Living Room", "Bedroom", "Kitchen", "Office", "Bathroom", "Hallway"]

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var devices: [DiscoveredDevice] { meshService.selectedDevicesForProvisioning }

    func createGroup() {
        guard !isConfiguring, !roomName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isConfiguring = true
        Task { await runGroupConfig() }
    }

    private func runGroupConfig() async {
        let steps = 4
        for step in 1...steps {
            configProgress = Double(step) / Double(steps)
            try? await Task.sleep(for: .milliseconds(600))
        }

        do {
            let nodes = meshService.provisionedNodes
            _ = try await meshService.configureGroup(name: roomName, nodes: nodes)
            try? await Task.sleep(for: .milliseconds(400))

            // Attempt proxy connection
            await meshService.connectToProxy()

            router.navigate(to: .deviceControl)
        } catch {
            errorMessage = error.localizedDescription
            isConfiguring = false
        }
    }
}
