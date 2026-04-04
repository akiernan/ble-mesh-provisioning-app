import Foundation

@Observable
@MainActor
final class GroupConfigViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var roomName = "Living Room"
    var isConfiguring = false
    var errorMessage: String?

    let suggestedRooms = ["Living Room", "Bedroom", "Kitchen", "Office", "Bathroom", "Hallway"]

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var devices: [DiscoveredDevice] { meshService.selectedDevicesForProvisioning }
    var configProgress: Double { meshService.groupConfigProgress }
    var configStatus: String { meshService.groupConfigStatus }
    var nodeGroupConfigStates: [NodeKeyBindingState] { meshService.nodeGroupConfigStates }

    func createGroup() {
        guard !isConfiguring, !roomName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isConfiguring = true
        Task { await runGroupConfig() }
    }

    private func runGroupConfig() async {
        do {
            let nodes = meshService.provisionedNodes
            _ = try await meshService.configureGroup(name: roomName, nodes: nodes)

            // Ensure proxy is still connected for device control.
            try? await meshService.connectToProxy()

            router.navigate(to: .switchCommissioning)
        } catch {
            errorMessage = error.localizedDescription
            isConfiguring = false
        }
    }
}
