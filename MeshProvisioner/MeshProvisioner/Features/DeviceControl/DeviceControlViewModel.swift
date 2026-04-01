import Foundation

@Observable
@MainActor
final class DeviceControlViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    /// Minimum interval between BLE sends while slider is being dragged.
    private static let throttleInterval: Duration = .milliseconds(150)

    /// Pending CTL values to send when the throttle window opens.
    private var pendingLightness: Double?
    private var pendingTemperature: UInt16?
    private var throttleTask: Task<Void, Never>?
    private var isSending = false

    var errorMessage: String?

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var group: MeshGroupConfig? { meshService.currentGroup }
    var isConnected: Bool { meshService.isConnectedToProxy }
    var deviceCount: Int { meshService.provisionedNodes.count }
    var deviceNames: [String] {
        meshService.provisionedNodes.map { $0.name ?? "Mesh Node" }
    }

    func connectIfNeeded() {
        guard !meshService.isConnectedToProxy else { return }
        Task { try? await meshService.connectToProxy() }
    }

    func togglePower() {
        guard let group else { return }
        Task {
            do {
                try await meshService.setOnOff(!group.isOn)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setLightness(_ lightness: Double) {
        // Update UI immediately
        meshService.currentGroup?.lightness = lightness
        guard let group = meshService.currentGroup else { return }
        pendingLightness = lightness
        pendingTemperature = group.temperature
        scheduleThrottledSend()
    }

    func setTemperature(_ temperature: Double) {
        let kelvin = UInt16(temperature)
        // Update UI immediately
        meshService.currentGroup?.temperature = kelvin
        guard let group = meshService.currentGroup else { return }
        pendingLightness = group.lightness
        pendingTemperature = kelvin
        scheduleThrottledSend()
    }

    func restart() {
        throttleTask?.cancel()
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

    // MARK: - Throttled Send

    /// Schedules a BLE send after the throttle interval. If a send is already
    /// in flight, the pending values will be picked up when it completes.
    private func scheduleThrottledSend() {
        // If already waiting to send, the pending values are updated — nothing else needed.
        guard throttleTask == nil else { return }

        throttleTask = Task {
            try? await Task.sleep(for: Self.throttleInterval)
            guard !Task.isCancelled else { return }
            await flushPendingCTL()
            throttleTask = nil

            // If new values arrived while we were sending, schedule another round.
            if pendingLightness != nil {
                scheduleThrottledSend()
            }
        }
    }

    private func flushPendingCTL() async {
        guard let lightness = pendingLightness,
              let temperature = pendingTemperature else { return }
        pendingLightness = nil
        pendingTemperature = nil

        do {
            try await meshService.setLightCTL(lightness: lightness, temperature: temperature)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
