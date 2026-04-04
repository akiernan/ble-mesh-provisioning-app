import Foundation
import UIKit
@preconcurrency import CoreBluetooth
@preconcurrency import NordicMesh
import os.log

// Module-level logger shared by all MeshNetworkService extension files.
let logger = Logger(subsystem: "uk.a-squared-projects.MeshProvisioner", category: "MeshNetworkService")

// MARK: - MeshNetworkService

@Observable
@MainActor
final class MeshNetworkService: NSObject {

    // MARK: Scanning State

    var discoveredDevices: [DiscoveredDevice] = []
    var isScanning = false
    var bluetoothState: CBManagerState = .unknown

    // MARK: Provisioning State

    var provisioningStates: [UUID: ProvisioningDeviceState] = [:]

    // MARK: Key Binding State

    var keyBindingStepStates: [KeyBindingStep: KeyBindingStepState] = Dictionary(
        uniqueKeysWithValues: KeyBindingStep.allCases.map { ($0, .pending) }
    )

    // MARK: Network State

    var meshNetwork: MeshNetwork? { manager.meshNetwork }
    var isConnectedToProxy = false
    var currentGroup: MeshGroupConfig?
    var error: Error?

    // MARK: Group Config Progress

    var groupConfigProgress: Double = 0
    var groupConfigStatus: String = ""

    // MARK: Per-Node Key Binding Progress

    var nodeKeyBindingStates: [NodeKeyBindingState] = []

    // MARK: Per-Node Group Config Progress

    var nodeGroupConfigStates: [NodeKeyBindingState] = []

    // MARK: Node Reset Progress

    var isResettingNodes = false
    var nodeResetCompleted = 0
    var nodeResetTotal = 0

    // MARK: Selection State (shared between screens)

    var selectedDevicesForProvisioning: [DiscoveredDevice] = []
    var provisionedNodes: [Node] = []

    // MARK: Internal implementation state (accessed by extension files)

    let manager: MeshNetworkManager
    var scannerCentralManager: CBCentralManager!
    let clientDelegate = LightControlClientDelegate()
    let serverDelegate = LightServerDelegate()

    // Provisioning helpers – each device gets its own PBGattBearer (own central manager)
    var activeProvisioningManagers: [UUID: ProvisioningManager] = [:]
    var provisioningContinuations: [UUID: CheckedContinuation<Node, Error>] = [:]
    // Strong reference to bearer delegates – PBGattBearer.delegate is weak
    var activeBearerDelegates: [UUID: ProvisioningBearerBridge] = [:]

    // Peripheral UUID → device UUID mapping (for scanning results)
    var peripheralIDToDeviceID: [UUID: UUID] = [:]
    var discoveredPeripheralMeshData: [UUID: Data] = [:]

    // Config message response continuations.
    // Keyed on (source unicast address, response opCode) — resolved from the delegate
    // when any message (including UnknownMessage) with the matching opCode arrives.
    var pendingConfigContinuations: [ConfigContinuationKey: CheckedContinuation<Void, Never>] = [:]

    // Proxy connection
    var proxyBearer: GattBearer?
    var proxyConnectionContinuation: CheckedContinuation<Void, Error>?

    // MARK: Init

    override init() {
        manager = MeshNetworkManager()
        super.init()
        scannerCentralManager = CBCentralManager(delegate: self, queue: .main)
        manager.delegate = self
        manager.logger = self
        setupMeshNetwork()
        setupLocalElements()
    }

    /// Installs local element models on the current mesh network.
    /// Must be called after every setupMeshNetwork() so the ConfigurationClientHandler
    /// is registered and can decode composition data / config response messages.
    private func setupLocalElements() {
        manager.localElements = [
            Element(name: "Primary Element", location: .unknown, models: [
                // Client models for sending commands and receiving acknowledged responses.
                Model(sigModelId: .genericOnOffClientModelId, delegate: clientDelegate),
                Model(sigModelId: .lightCTLClientModelId, delegate: clientDelegate),
                // Server models subscribed to the main group (0xC001) so the proxy
                // filter forwards lightness / on-off commands from the external dimmer.
                Model(sigModelId: .genericOnOffServerModelId, delegate: serverDelegate),
                Model(sigModelId: .genericLevelServerModelId, delegate: serverDelegate),
                Model(sigModelId: .lightLightnessServerModelId, delegate: serverDelegate),
                Model(sigModelId: .lightLightnessSetupServerModelId, delegate: serverDelegate),
                Model(sigModelId: .lightCTLServerModelId, delegate: serverDelegate),
                Model(sigModelId: .lightCTLSetupServerModelId, delegate: serverDelegate),
            ]),
            // CTL temperature element – mirrors the secondary element on lighting nodes.
            // Subscribed to 0xC002 so Generic Level messages from the Silvair switch's
            // second controller reach us and are interpreted as colour-temperature changes.
            Element(name: "CTL Temperature Element", location: .unknown, models: [
                Model(sigModelId: .genericLevelServerModelId, delegate: serverDelegate),
                Model(sigModelId: .lightCTLTemperatureServerModelId, delegate: serverDelegate),
            ]),
        ]
        // Use a reject list with no rejected addresses (= accept everything) so that
        // group-addressed messages are always forwarded by the GATT proxy, regardless
        // of when local model subscriptions are added relative to the proxy connection.
        // ProxyFilter.add(address:) is internal-only, so we cannot update the accept
        // list mid-session after group config subscribes local models to 0xC001.
        manager.proxyFilter.initialState = .rejectList(addresses: [])
    }

    // MARK: - Network Setup

    private func setupMeshNetwork() {
        do {
            if !(try manager.load()) {
                let deviceName = UIDevice.current.name
                let network = manager.createNewMeshNetwork(
                    withName: "Zuma Network",
                    by: deviceName
                )
                // createNewMeshNetwork adds a default net key at index 0.
                // Only add our own if none exists.
                let netKey: NetworkKey
                if let existing = network.networkKeys.first {
                    netKey = existing
                } else {
                    netKey = try network.add(
                        networkKey: Data.random128BitKey(),
                        withIndex: 0,
                        name: "Primary Network Key"
                    )
                }
                if network.applicationKeys.isEmpty {
                    let appKey = try network.add(
                        applicationKey: Data.random128BitKey(),
                        withIndex: 0,
                        name: "Light CTL App Key"
                    )
                    try appKey.bind(to: netKey)
                }
            }
            _ = manager.save()
            restoreStateFromNetwork()
        } catch {
            self.error = error
            logger.error("Failed to set up mesh network: \(error)")
        }
    }

    /// Restores transient state from the persisted mesh network so the app
    /// can skip straight to the control screen on relaunch.
    private func restoreStateFromNetwork() {
        guard let network = manager.meshNetwork else { return }

        // Restore provisioned nodes (all nodes except the local provisioner)
        let localProvisioner = network.localProvisioner
        let remoteNodes = network.nodes.filter { $0.uuid != localProvisioner?.node?.uuid }
        guard !remoteNodes.isEmpty else { return }
        provisionedNodes = remoteNodes

        // Restore group config from persisted group at 0xC001
        let groupAddress: Address = 0xC001
        guard let group = network.group(withAddress: MeshAddress(groupAddress)) else { return }

        currentGroup = MeshGroupConfig(
            id: UUID().uuidString,
            name: group.name,
            groupAddress: groupAddress,
            nodeUnicastAddresses: remoteNodes.map { $0.primaryUnicastAddress },
            isOn: false,
            lightness: 0.5,
            temperature: 4000
        )
        logger.info("Restored network: \(remoteNodes.count) node(s), group '\(group.name)'")
    }

    /// Whether the persisted network has provisioned nodes and a configured group,
    /// meaning the app can skip directly to the device control screen.
    var hasProvisionedNetwork: Bool {
        currentGroup != nil && !provisionedNodes.isEmpty
    }

    /// Sends ConfigNodeReset to every provisioned node (so they return to
    /// unprovisioned state and can be discovered again), then wipes local state.
    func factoryResetAllNodes() async {
        let nodes = provisionedNodes
        isResettingNodes = true
        nodeResetTotal = nodes.count
        nodeResetCompleted = 0
        for node in nodes {
            logger.info("🔄 Sending ConfigNodeReset to \(node.name ?? "?")")
            await sendConfig(ConfigNodeReset(), to: node)
            nodeResetCompleted += 1
        }
        try? await Task.sleep(for: .milliseconds(800))
        isResettingNodes = false
        resetMeshNetwork()
    }

    /// Wipes the persisted mesh network and resets all state so the user can
    /// start the provisioning flow from scratch.
    func resetMeshNetwork() {
        // Disconnect proxy
        proxyBearer?.close()
        proxyBearer = nil
        manager.transmitter = nil
        isConnectedToProxy = false
        proxyConnectionContinuation?.resume(throwing: AppError.networkNotReady)
        proxyConnectionContinuation = nil

        // Stop scanning
        scannerCentralManager.stopScan()
        isScanning = false

        // Delete persisted MeshNetwork.json
        if let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("MeshNetwork.json") {
            try? FileManager.default.removeItem(at: url)
        }

        // Reset observable state
        discoveredDevices = []
        selectedDevicesForProvisioning = []
        provisionedNodes = []
        currentGroup = nil
        provisioningStates = [:]
        keyBindingStepStates = Dictionary(uniqueKeysWithValues: KeyBindingStep.allCases.map { ($0, .pending) })
        groupConfigProgress = 0
        groupConfigStatus = ""
        nodeKeyBindingStates = []
        nodeGroupConfigStates = []
        error = nil
        peripheralIDToDeviceID = [:]
        discoveredPeripheralMeshData = [:]

        // Create a fresh network and reinstall model delegates
        setupMeshNetwork()
        setupLocalElements()
        logger.info("Mesh network reset to factory defaults")
    }
}

// MARK: - ConfigContinuationKey

struct ConfigContinuationKey: Hashable {
    let sourceAddress: UInt16
    let responseOpCode: UInt32
}

// MARK: - LightControlClientDelegate

/// Model delegate for local GenericOnOff Client and LightCTL Client models.
/// Registers the response opcodes so the library decodes status messages
/// instead of returning UnknownMessage.
class LightControlClientDelegate: ModelDelegate {
    let messageTypes: [UInt32: MeshMessage.Type]
    let isSubscriptionSupported = false
    let publicationMessageComposer: MessageComposer? = nil

    init() {
        self.messageTypes = [
            // Application-level status messages
            GenericOnOffStatus.opCode: GenericOnOffStatus.self,
            LightCTLStatus.opCode: LightCTLStatus.self,
            LightCTLTemperatureRangeStatus.opCode: LightCTLTemperatureRangeStatus.self,
            LightLightnessRangeStatus.opCode: LightLightnessRangeStatus.self,
            // Configuration response messages — registering these opcodes here ensures
            // the library decodes them as typed messages rather than UnknownMessage,
            // which allows the manager.send() continuations to resolve immediately
            // instead of falling back to the 8-second withTimeout.
            ConfigCompositionDataStatus.opCode: ConfigCompositionDataStatus.self,
            ConfigAppKeyStatus.opCode: ConfigAppKeyStatus.self,
            ConfigModelAppStatus.opCode: ConfigModelAppStatus.self,
            ConfigModelSubscriptionStatus.opCode: ConfigModelSubscriptionStatus.self,
            ConfigModelPublicationStatus.opCode: ConfigModelPublicationStatus.self,
        ]
    }

    func model(_ model: Model,
               didReceiveAcknowledgedMessage request: AcknowledgedMeshMessage,
               from source: Address,
               sentTo destination: MeshAddress) throws -> MeshResponse {
        fatalError("Client model does not handle acknowledged requests")
    }

    func model(_ model: Model,
               didReceiveUnacknowledgedMessage message: UnacknowledgedMeshMessage,
               from source: Address,
               sentTo destination: MeshAddress) {
        // Nothing to do
    }

    func model(_ model: Model,
               didReceiveResponse response: MeshResponse,
               toAcknowledgedMessage request: AcknowledgedMeshMessage,
               from source: Address) {
        // Response handled by the async send() caller
    }
}

// MARK: - LightServerDelegate

/// Model delegate for local GenericOnOff Server and LightCTL Server models.
/// Registering these opcodes allows the library to:
///   1. Decode incoming Set/Status messages so MeshNetworkDelegate.didReceiveMessage
///      receives typed messages rather than UnknownMessage.
///   2. Subscribe the local models to the group address, which causes the proxy filter
///      to include the group so the GATT proxy forwards those messages to us.
class LightServerDelegate: ModelDelegate {
    let isSubscriptionSupported = true
    let publicationMessageComposer: MessageComposer? = nil

    let messageTypes: [UInt32: MeshMessage.Type] = [
        GenericOnOffSetUnacknowledged.opCode: GenericOnOffSetUnacknowledged.self,
        GenericOnOffStatus.opCode: GenericOnOffStatus.self,
        GenericLevelSet.opCode: GenericLevelSet.self,
        GenericLevelSetUnacknowledged.opCode: GenericLevelSetUnacknowledged.self,
        GenericDeltaSetUnacknowledged.opCode: GenericDeltaSetUnacknowledged.self,
        GenericLevelStatus.opCode: GenericLevelStatus.self,
        LightLightnessSetUnacknowledged.opCode: LightLightnessSetUnacknowledged.self,
        LightLightnessStatus.opCode: LightLightnessStatus.self,
        LightCTLSetUnacknowledged.opCode: LightCTLSetUnacknowledged.self,
        LightCTLStatus.opCode: LightCTLStatus.self,
    ]

    func model(_ model: Model,
               didReceiveAcknowledgedMessage request: AcknowledgedMeshMessage,
               from source: Address,
               sentTo destination: MeshAddress) throws -> MeshResponse {
        // GenericLevelSet (0x8206) is the acknowledged variant sent by some dimmers.
        // Return the current level as a status response.
        if let cmd = request as? GenericLevelSet {
            return GenericLevelStatus(level: cmd.level)
        }
        fatalError("LightServerDelegate received unexpected acknowledged message: \(request)")
    }

    func model(_ model: Model,
               didReceiveUnacknowledgedMessage message: UnacknowledgedMeshMessage,
               from source: Address,
               sentTo destination: MeshAddress) {
        // State updates are handled centrally in MeshNetworkDelegate.didReceiveMessage.
    }

    func model(_ model: Model,
               didReceiveResponse response: MeshResponse,
               toAcknowledgedMessage request: AcknowledgedMeshMessage,
               from source: Address) {
        // Not applicable for server models.
    }
}
