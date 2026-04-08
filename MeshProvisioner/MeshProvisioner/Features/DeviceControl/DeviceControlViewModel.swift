import Foundation

@Observable
@MainActor
final class DeviceControlViewModel {

    private let meshService: MeshNetworkService
    private let router: AppRouter

    /// Most-recent slider values waiting to be sent. Overwritten on each slider
    /// move so only the latest value is ever sent, preventing queue build-up.
    private var pendingLightness: Double?
    private var pendingTemperature: UInt16?
    /// True while an acknowledged CTL send is in-flight. New slider values
    /// accumulate in pending* and are dispatched as soon as the ACK arrives.
    private var isSending = false

    var errorMessage: String?

    init(meshService: MeshNetworkService, router: AppRouter) {
        self.meshService = meshService
        self.router = router
    }

    var group: MeshGroupConfig? { meshService.currentGroup }
    var isConnected: Bool { meshService.isConnectedToProxy }
    var deviceCount: Int { meshService.provisionedNodes.count }
    var provisionedDevices: [(name: String, unicastAddress: UInt16)] {
        meshService.provisionedNodes.map { ($0.name ?? "Mesh Node", $0.primaryUnicastAddress) }
    }

    var isResetting: Bool { meshService.isResettingNodes }
    var resetCompleted: Int { meshService.nodeResetCompleted }
    var resetTotal: Int { meshService.nodeResetTotal }

    func connectIfNeeded() {
        Task {
            do {
                try await meshService.connectToProxy()
            } catch {
                errorMessage = "Proxy connection failed: \(error.localizedDescription)"
                return
            }
            await meshService.fetchCurrentState()
        }
    }

    func togglePower() {
        guard let group else { return }
        let turningOn = !group.isOn
        Task {
            do {
                try await meshService.setOnOff(turningOn)
                if turningOn { await meshService.fetchCurrentState() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func setLightness(_ lightness: Double) {
        // Update UI immediately; mirror OnOff bound state
        meshService.currentGroup?.lightness = lightness
        if lightness == 0 { meshService.currentGroup?.isOn = false }
        else if meshService.currentGroup?.isOn == false { meshService.currentGroup?.isOn = true }
        guard let group = meshService.currentGroup else { return }
        pendingLightness = lightness
        pendingTemperature = group.temperature
        triggerSendIfIdle()
    }

    func setTemperature(_ temperature: Double) {
        let kelvin = UInt16(temperature)
        // Update UI immediately
        meshService.currentGroup?.temperature = kelvin
        guard let group = meshService.currentGroup else { return }
        pendingLightness = group.lightness
        pendingTemperature = kelvin
        triggerSendIfIdle()
    }

    func restart() {
        Task {
            await meshService.factoryResetAllNodes()
            router.popToRoot()
        }
    }

    func resetLocalOnly() {
        Task {
            meshService.resetMeshNetwork()
            router.popToRoot()
        }
    }

    // MARK: - ACK-gated Send

    private func triggerSendIfIdle() {
        guard !isSending else { return }
        isSending = true
        Task { await sendLoop() }
    }

    /// Drains pending CTL values one at a time. A minimum gap between sends
    /// prevents the BLE bearer from being flooded with queued messages.
    private func sendLoop() async {
        while let lightness = pendingLightness, let temperature = pendingTemperature {
            pendingLightness = nil
            pendingTemperature = nil
            do {
                try await meshService.setLightCTL(lightness: lightness, temperature: temperature)
            } catch {
                errorMessage = error.localizedDescription
            }
            // Give the bearer time to transmit before we send the next value.
            try? await Task.sleep(for: .milliseconds(100))
        }
        isSending = false
    }
}
