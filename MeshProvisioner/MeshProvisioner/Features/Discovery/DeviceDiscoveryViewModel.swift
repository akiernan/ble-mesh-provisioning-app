import Foundation

@Observable
@MainActor
final class DeviceDiscoveryViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var selectedIDs: Set<UUID> = []

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var discoveredDevices: [DiscoveredDevice] { meshService.discoveredDevices }
    var isScanning: Bool { meshService.isScanning }
    var bluetoothReady: Bool { meshService.bluetoothState == .poweredOn }
    var selectedCount: Int { selectedIDs.count }

    var selectedDevices: [DiscoveredDevice] {
        meshService.discoveredDevices.filter { selectedIDs.contains($0.id) }
    }

    func startScanning() {
        meshService.startScanning()
    }

    func stopScanning() {
        meshService.stopScanning()
    }

    func toggle(_ device: DiscoveredDevice) {
        if selectedIDs.contains(device.id) {
            selectedIDs.remove(device.id)
        } else {
            selectedIDs.insert(device.id)
        }
    }

    func isSelected(_ device: DiscoveredDevice) -> Bool {
        selectedIDs.contains(device.id)
    }

    func continueToProvisioning() {
        meshService.stopScanning()
        // Store selected devices in service for use by the provisioning screen
        meshService.selectedDevicesForProvisioning = selectedDevices
        router.navigate(to: .provisioning)
    }
}
