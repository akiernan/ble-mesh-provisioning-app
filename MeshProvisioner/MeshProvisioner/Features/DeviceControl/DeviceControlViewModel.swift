import Foundation

@Observable
@MainActor
final class DeviceControlViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    var errorMessage: String?

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var group: MeshGroupConfig? { meshService.currentGroup }
    var isConnected: Bool { meshService.isConnectedToProxy }
    var deviceCount: Int { meshService.selectedDevicesForProvisioning.count }
    var deviceNames: [String] { meshService.selectedDevicesForProvisioning.map(\.name) }

    func togglePower() {
        guard let group else { return }
        do {
            try meshService.setOnOff(!group.isOn)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setLightness(_ lightness: Double) {
        guard let group else { return }
        do {
            try meshService.setLightCTL(lightness: lightness, temperature: group.temperature)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setTemperature(_ temperature: Double) {
        guard let group else { return }
        let kelvin = UInt16(temperature)
        do {
            try meshService.setLightCTL(lightness: group.lightness, temperature: kelvin)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func restart() {
        meshService.selectedDevicesForProvisioning = []
        meshService.provisionedNodes = []
        meshService.discoveredDevices = []
        meshService.currentGroup = nil
        meshService.provisioningStates = [:]
        meshService.keyBindingStepStates = Dictionary(
            uniqueKeysWithValues: KeyBindingStep.allCases.map { ($0, .pending) }
        )
        router.popToRoot()
    }
}
