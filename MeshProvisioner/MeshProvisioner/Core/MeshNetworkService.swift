import Foundation
import UIKit
@preconcurrency import CoreBluetooth
@preconcurrency import NordicMesh
import os.log

private let logger = Logger(subsystem: "uk.a-squared-projects.MeshProvisioner", category: "MeshNetworkService")

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

    // MARK: Private

    private let manager: MeshNetworkManager
    private var scannerCentralManager: CBCentralManager!
    private let clientDelegate = LightControlClientDelegate()
    private let serverDelegate = LightServerDelegate()

    // Provisioning helpers – each device gets its own PBGattBearer (own central manager)
    private var activeProvisioningManagers: [UUID: ProvisioningManager] = [:]
    private var provisioningContinuations: [UUID: CheckedContinuation<Node, Error>] = [:]
    // Strong reference to bearer delegates – PBGattBearer.delegate is weak
    private var activeBearerDelegates: [UUID: ProvisioningBearerBridge] = [:]

    // Peripheral UUID → device UUID mapping (for scanning results)
    private var peripheralIDToDeviceID: [UUID: UUID] = [:]
    private var discoveredPeripheralMeshData: [UUID: Data] = [:]

    // Config message response continuations.
    // Keyed on (source unicast address, response opCode) — resolved from the delegate
    // when any message (including UnknownMessage) with the matching opCode arrives.
    // This works around manager.send() continuations not resolving when responses
    // arrive as UnknownMessage due to the ConfigurationClientHandler not decoding them.
    private var pendingConfigContinuations: [ConfigContinuationKey: CheckedContinuation<Void, Never>] = [:]

    // Proxy connection
    private var proxyBearer: GattBearer?
    private var proxyConnectionContinuation: CheckedContinuation<Void, Error>?

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
                Model(sigModelId: .genericDefaultTransitionTimeServerModelId, delegate: serverDelegate),
                Model(sigModelId: .genericPowerOnOffServerModelId, delegate: serverDelegate),
                Model(sigModelId: .genericPowerOnOffSetupServerModelId, delegate: serverDelegate),
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
                Model(sigModelId: .genericDefaultTransitionTimeServerModelId, delegate: serverDelegate),
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

    // MARK: - Scanning

    func startScanning() {
        guard bluetoothState == .poweredOn else { return }
        discoveredDevices = []
        peripheralIDToDeviceID = [:]
        discoveredPeripheralMeshData = [:]
        isScanning = true
        scannerCentralManager.scanForPeripherals(
            withServices: [MeshProvisioningService.uuid],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("Started scanning for unprovisioned devices")
    }

    func stopScanning() {
        scannerCentralManager.stopScan()
        isScanning = false
        logger.info("Stopped scanning")
    }

    // MARK: - Provisioning

    /// Provisions a single device. Returns the provisioned Node on success.
    func provisionDevice(_ device: DiscoveredDevice) async throws -> Node {
        guard let peripheral = scannerCentralManager.retrievePeripherals(
            withIdentifiers: [device.peripheral.identifier]).first else {
            // Fallback: use stored peripheral directly
            return try await provisionWithPeripheral(device: device,
                                                      peripheral: device.peripheral)
        }
        return try await provisionWithPeripheral(device: device, peripheral: peripheral)
    }

    private func provisionWithPeripheral(device: DiscoveredDevice,
                                          peripheral: CBPeripheral) async throws -> Node {
        guard let network = manager.meshNetwork else { throw AppError.networkNotReady }

        let storedMeshData = discoveredPeripheralMeshData[device.peripheral.identifier]
        let unprovisionedDevice = UnprovisionedDevice(
            name: device.name,
            uuid: device.id,
            oobInformation: oobInfo(from: storedMeshData)
        )

        _ = network

        return try await withCheckedThrowingContinuation { continuation in
            let bearer = PBGattBearer(targetWithIdentifier: peripheral.identifier)
            bearer.logger = self

            do {
                let pm = try manager.provision(unprovisionedDevice: unprovisionedDevice,
                                               over: bearer)
                pm.delegate = self
                pm.logger = self

                activeProvisioningManagers[device.id] = pm
                provisioningContinuations[device.id] = continuation
                peripheralIDToDeviceID[peripheral.identifier] = device.id

                let bridge = ProvisioningBearerBridge(
                    deviceID: device.id,
                    provisioningManager: pm,
                    onOpen: { [weak self] in
                        Task { @MainActor [weak self] in
                            self?.handleBearerDidOpen(deviceID: device.id, pm: pm)
                        }
                    },
                    onClose: { [weak self] error in
                        Task { @MainActor [weak self] in
                            if let error {
                                self?.finishProvisioning(id: device.id,
                                                         result: .failure(error))
                            }
                        }
                    }
                )
                // Keep a strong reference — bearer.delegate is weak
                activeBearerDelegates[device.id] = bridge
                bearer.delegate = bridge
                bearer.open()
            } catch {
                provisioningContinuations.removeValue(forKey: device.id)
                continuation.resume(throwing: AppError.provisioningFailed(error.localizedDescription))
            }
        }
    }

    private func handleBearerDidOpen(deviceID: UUID, pm: ProvisioningManager) {
        do {
            try pm.identify(andAttractFor: 0)
        } catch {
            finishProvisioning(id: deviceID,
                               result: .failure(AppError.provisioningFailed(error.localizedDescription)))
        }
    }

    private func oobInfo(from meshData: Data?) -> OobInformation {
        if let meshData, meshData.count >= 18 {
            return OobInformation(rawValue: UInt16(meshData[16]) | (UInt16(meshData[17]) << 8))
        }
        return OobInformation(rawValue: 0)
    }

    @MainActor
    private func finishProvisioning(id: UUID, result: Result<Node, Error>) {
        activeProvisioningManagers.removeValue(forKey: id)
        activeBearerDelegates.removeValue(forKey: id)
        guard let cont = provisioningContinuations.removeValue(forKey: id) else { return }
        switch result {
        case .success(let node):
            provisioningStates[id] = .completed
            cont.resume(returning: node)
        case .failure(let error):
            provisioningStates[id] = .failed(error.localizedDescription)
            cont.resume(throwing: error)
        }
    }

    // MARK: - Message Sending

    /// Sends an acknowledged config message and waits until the expected response
    /// opCode arrives from that node (or 8 seconds elapse).
    ///
    /// This works around the library bug where `manager.send()` never resolves when
    /// the device's response arrives as `UnknownMessage`: we match on the raw opCode
    /// value directly in our delegate callback, which fires regardless of type.
    private func sendConfig(_ message: AcknowledgedConfigMessage, to node: Node) async {
        let key = ConfigContinuationKey(
            sourceAddress: node.primaryUnicastAddress,
            responseOpCode: message.responseOpCode
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingConfigContinuations[key] = cont
            Task { [manager] in _ = try? await manager.send(message, to: node) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                if let cont = pendingConfigContinuations.removeValue(forKey: key) {
                    logger.warning("🔧 Config send to 0x\(String(node.primaryUnicastAddress, radix: 16)) timed out")
                    cont.resume()
                }
            }
        }
    }

    /// Runs an async operation with a timeout. If the timeout fires first, execution
    /// continues immediately — the operation is left running in the background but
    /// does not block progress. This is critical because `manager.send()` can hang
    /// forever when proxy notifications aren't working and the response is never received.
    private func withTimeout(
        _ timeout: Duration = .seconds(8),
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        let gate = OnceGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                try? await operation()
                if gate.tryPass() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.tryPass() {
                    logger.warning("Config message timed out — continuing")
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Key Binding

    func performKeyBinding(nodes: [Node]) async throws {
        guard let network = manager.meshNetwork else { throw AppError.networkNotReady }

        // Step 0: Connect to GATT proxy
        keyBindingStepStates[.connectProxy] = .inProgress
        // Allow the device to transition from PB-GATT provisioning to proxy mode
        try await Task.sleep(for: .seconds(2))
        try await connectToProxy()
        keyBindingStepStates[.connectProxy] = .completed

        // Step 1: Generate / retrieve application key
        keyBindingStepStates[.generateKey] = .inProgress
        let appKey: ApplicationKey
        if let existing = network.applicationKeys.first {
            appKey = existing
        } else {
            guard let netKey = network.networkKeys.first else {
                throw AppError.keyBindingFailed("No network key found")
            }
            appKey = try network.add(applicationKey: Data.random128BitKey(),
                                     withIndex: 0, name: "Light CTL App Key")
            try appKey.bind(to: netKey)
        }
        try await Task.sleep(for: .milliseconds(300))
        keyBindingStepStates[.generateKey] = .completed

        // Step 2: Distribute keys – fetch composition data then send ConfigAppKeyAdd
        keyBindingStepStates[.distributeKeys] = .inProgress
        nodeKeyBindingStates = nodes.map {
            NodeKeyBindingState(id: $0.uuid, name: $0.name ?? "Mesh Node", state: .pending)
        }
        for node in nodes {
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .inProgress
            }
            logger.info("🔧 Processing node: \(node.name ?? "unknown"), unicast: 0x\(String(node.primaryUnicastAddress, radix: 16)), elements: \(node.elements.count)")
            logger.info("🔧 Proxy connected: \(self.isConnectedToProxy), transmitter: \(self.manager.transmitter != nil), bearer: \(self.proxyBearer != nil)")

            // Fetch composition data so we know the node's elements and models.
            // After provisioning, elements exist (from capabilities) but have no models.
            // We need composition data to populate model info on each element.
            let hasModels = node.elements.contains { !$0.models.isEmpty }
            if !hasModels {
                logger.info("🔧 Sending ConfigCompositionDataGet to node 0x\(String(node.primaryUnicastAddress, radix: 16)) (\(node.elements.count) elements, no models)...")
                let compositionGet = ConfigCompositionDataGet(page: 0)
                logger.info("🔧 manager.send(CompositionDataGet) — awaiting response...")
                await sendConfig(compositionGet, to: node)
                try? await Task.sleep(for: .milliseconds(500))
                logger.info("🔧 After CompositionDataGet — node elements: \(node.elements.count)")
                for (i, element) in node.elements.enumerated() {
                    let modelNames = element.models.map { "0x\(String($0.modelId, radix: 16))" }.joined(separator: ", ")
                    logger.info("🔧   Element[\(i)] addr=0x\(String(element.unicastAddress, radix: 16)) models=[\(modelNames)]")
                }
            } else {
                logger.info("🔧 Node already has composition data (\(node.elements.count) elements)")
            }

            logger.info("🔧 Sending ConfigAppKeyAdd to node 0x\(String(node.primaryUnicastAddress, radix: 16))...")
            let request = ConfigAppKeyAdd(applicationKey: appKey)
            await sendConfig(request, to: node)
            try? await Task.sleep(for: .milliseconds(200))
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .completed
            }
        }
        keyBindingStepStates[.distributeKeys] = .completed

        // Step 3: Configure model binding on each node
        keyBindingStepStates[.configureModels] = .inProgress
        nodeKeyBindingStates = nodes.map {
            NodeKeyBindingState(id: $0.uuid, name: $0.name ?? "Mesh Node", state: .pending)
        }
        for node in nodes {
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .inProgress
            }
            let hasModels = node.elements.contains { !$0.models.isEmpty }
            if !hasModels {
                logger.warning("🔧 Node \(node.name ?? "unknown") has no models — skipping model bind")
                if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                    nodeKeyBindingStates[idx].state = .completed
                }
                continue
            }
            for (i, element) in node.elements.enumerated() {
                let modelNames = element.models.map { "0x\(String($0.modelId, radix: 16))" }.joined(separator: ", ")
                logger.info("🔧 Element[\(i)] models: [\(modelNames)]")
                for model in element.models {
                    // Bind app key to every non-config SIG model
                    let modelId = model.modelId
                    guard modelId != 0x0000 && modelId != 0x0001 else { continue } // skip config server/client
                    if let bindMsg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        logger.info("🔧 Binding app key to model 0x\(String(modelId, radix: 16)) on element \(i)")
                        await sendConfig(bindMsg, to: node)
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .completed
            }
        }
        keyBindingStepStates[.configureModels] = .completed

        _ = manager.save()
    }

    // MARK: - Group Configuration

    func configureGroup(name: String, nodes: [Node]) async throws -> MeshGroupConfig {
        guard let network = manager.meshNetwork else { throw AppError.networkNotReady }

        // Ensure proxy connection is active
        if !isConnectedToProxy {
            try await connectToProxy()
        }

        // Main lighting group: OnOff / Level / Lightness / CTL commands
        let mainGroupAddress: Address = 0xC001
        let mainGroup: Group
        if let existing = network.group(withAddress: MeshAddress(mainGroupAddress)) {
            mainGroup = existing
        } else {
            do {
                mainGroup = try Group(name: name, address: MeshAddress(mainGroupAddress))
                try network.add(group: mainGroup)
            } catch {
                throw AppError.groupConfigFailed(error.localizedDescription)
            }
        }

        // CTL temperature group: Generic Level commands from the Silvair switch's second controller
        let ctlTempGroupAddress: Address = 0xC002
        let ctlTempGroup: Group
        if let existing = network.group(withAddress: MeshAddress(ctlTempGroupAddress)) {
            ctlTempGroup = existing
        } else {
            do {
                ctlTempGroup = try Group(name: "\(name) CTL Temperature", address: MeshAddress(ctlTempGroupAddress))
                try network.add(group: ctlTempGroup)
            } catch {
                throw AppError.groupConfigFailed(error.localizedDescription)
            }
        }

        guard let appKey = network.applicationKeys.first else {
            throw AppError.groupConfigFailed("No application key available")
        }

        // Models that bind transitively to Light CTL Server / Light Lightness Server.
        // These live in the primary lighting element and should all subscribe to the group.
        let ctlLightnessBindingIds: Set<UInt16> = [
            .genericOnOffServerModelId,                 // 0x1000
            .genericLevelServerModelId,                 // 0x1002
            .genericDefaultTransitionTimeServerModelId, // 0x1004
            .genericPowerOnOffServerModelId,            // 0x1006
            .genericPowerOnOffSetupServerModelId,       // 0x1007
            .lightLightnessServerModelId,               // 0x1300
            .lightLightnessSetupServerModelId,          // 0x1301
            .lightCTLServerModelId,                     // 0x1303
            .lightCTLSetupServerModelId,                // 0x1304
        ]

        // Models that bind transitively to Light CTL Temperature Server.
        // These live in the secondary CTL temperature element.
        let ctlTempBindingIds: Set<UInt16> = [
            .genericLevelServerModelId,                 // 0x1002
            .genericDefaultTransitionTimeServerModelId, // 0x1004
            .lightCTLTemperatureServerModelId,          // 0x1306
        ]

        // Silvair vendor model (CID 0x0136, ModelID 0x0001) identifies a switch element.
        let silvairVendorModelId: UInt32 = (UInt32(0x0136) << 16) | UInt32(0x0001)
        // OnOff + Level clients in the Silvair element publish to the main lighting group.
        let switchClientIds: Set<UInt16> = [
            .genericOnOffClientModelId, // 0x1001
            .genericLevelClientModelId, // 0x1003
        ]
        let mainSwitchPublication = Publish(
            to: MeshAddress(mainGroupAddress),
            using: appKey,
            usingFriendshipMaterial: false,
            ttl: 5,
            period: .disabled,
            retransmit: .disabled
        )
        // The Level Client in the element immediately after the Silvair element publishes
        // to the CTL temperature group so the second controller controls colour temperature.
        let ctlTempPublication = Publish(
            to: MeshAddress(ctlTempGroupAddress),
            using: appKey,
            usingFriendshipMaterial: false,
            ttl: 5,
            period: .disabled,
            retransmit: .disabled
        )

        // Helper: which models should subscribe, and to which group.
        // Primary lighting element → main group; CTL temp element → CTL temp group.
        func subscribeTarget(for element: Element) -> (ids: Set<UInt16>, group: Group)? {
            let ids = Set(element.models.map { $0.modelIdentifier })
            if ids.contains(.lightCTLServerModelId) || ids.contains(.lightLightnessServerModelId) {
                return (ctlLightnessBindingIds, mainGroup)
            } else if ids.contains(.lightCTLTemperatureServerModelId) {
                return (ctlTempBindingIds, ctlTempGroup)
            }
            return nil
        }

        // Models for local provisioner element 0 → bound and subscribed to main group (0xC001).
        let localServerIds: Set<UInt16> = [
            .genericOnOffServerModelId,
            .genericLevelServerModelId,
            .genericDefaultTransitionTimeServerModelId,
            .genericPowerOnOffServerModelId,
            .genericPowerOnOffSetupServerModelId,
            .lightLightnessServerModelId,
            .lightLightnessSetupServerModelId,
            .lightCTLServerModelId,
            .lightCTLSetupServerModelId,
        ]
        // Models for local provisioner element 1 → bound and subscribed to CTL temp group (0xC002).
        let localCTLTempServerIds: Set<UInt16> = [
            .genericLevelServerModelId,
            .genericDefaultTransitionTimeServerModelId,
        ]

        // Count total BLE operations upfront for progress reporting.
        var totalOps = 0
        for node in nodes {
            let elements = Array(node.elements)
            for (elementIndex, element) in elements.enumerated() {
                let target = subscribeTarget(for: element)
                let hasSilvair = element.models.contains(where: { $0.modelId == silvairVendorModelId })
                for model in element.models {
                    if let t = target, t.ids.contains(model.modelIdentifier),
                       ConfigModelSubscriptionAdd(group: t.group, to: model) != nil { totalOps += 1 }
                    if hasSilvair && switchClientIds.contains(model.modelIdentifier),
                       ConfigModelPublicationSet(mainSwitchPublication, to: model) != nil { totalOps += 1 }
                }
                // Level Client in element+1 after the Silvair element → CTL temp group
                if hasSilvair && elementIndex + 1 < elements.count {
                    let nextEl = elements[elementIndex + 1]
                    for model in nextEl.models where model.modelIdentifier == .genericLevelClientModelId {
                        if ConfigModelPublicationSet(ctlTempPublication, to: model) != nil { totalOps += 1 }
                    }
                }
            }
        }
        // Include local provisioner ops: element 0 → main group, element 1 → CTL temp group.
        let localNode = network.localProvisioner?.node
        let localName = localNode?.name ?? "This Device"
        if let localNode {
            let localElements = Array(localNode.elements)
            if !localElements.isEmpty {
                for model in localElements[0].models where localServerIds.contains(model.modelIdentifier) {
                    totalOps += 2 // ConfigModelAppBind + ConfigModelSubscriptionAdd
                }
            }
            if localElements.count > 1 {
                for model in localElements[1].models where localCTLTempServerIds.contains(model.modelIdentifier) {
                    totalOps += 2 // ConfigModelAppBind + ConfigModelSubscriptionAdd
                }
            }
        }
        totalOps = max(1, totalOps)
        var completedOps = 0

        groupConfigProgress = 0
        groupConfigStatus = "Starting…"
        var initialStates = nodes.enumerated().map { idx, node in
            NodeKeyBindingState(id: node.uuid, name: node.name ?? "Device \(idx + 1)", state: .pending)
        }
        if let localNode {
            initialStates.append(NodeKeyBindingState(id: localNode.uuid, name: localName, state: .pending))
        }
        nodeGroupConfigStates = initialStates

        for (nodeIndex, node) in nodes.enumerated() {
            let nodeName = node.name ?? "Device \(nodeIndex + 1)"
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeGroupConfigStates[idx].state = .inProgress
            }
            let elements = Array(node.elements)
            for (elementIndex, element) in elements.enumerated() {
                let target = subscribeTarget(for: element)
                let hasSilvair = element.models.contains(where: { $0.modelId == silvairVendorModelId })
                for model in element.models {
                    // Subscribe lighting models to the appropriate group
                    if let t = target, t.ids.contains(model.modelIdentifier),
                       let msg = ConfigModelSubscriptionAdd(group: t.group, to: model) {
                        groupConfigStatus = "Subscribing \(nodeName) to group…"
                        logger.info("🔧 Subscribing model 0x\(String(model.modelId, radix: 16)) to \(t.group.name)")
                        await sendConfig(msg, to: node)
                        try? await Task.sleep(for: .milliseconds(200))
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                    // Silvair main controller: OnOff + Level publish to main group
                    if hasSilvair && switchClientIds.contains(model.modelIdentifier),
                       let msg = ConfigModelPublicationSet(mainSwitchPublication, to: model) {
                        groupConfigStatus = "Configuring switch publish on \(nodeName)…"
                        logger.info("🔧 Configuring switch client 0x\(String(model.modelId, radix: 16)) → 0xC001")
                        await sendConfig(msg, to: node)
                        try? await Task.sleep(for: .milliseconds(200))
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                }
                // Silvair element+1: Level Client publishes to CTL temp group (OnOff ignored)
                if hasSilvair && elementIndex + 1 < elements.count {
                    let nextEl = elements[elementIndex + 1]
                    for model in nextEl.models where model.modelIdentifier == .genericLevelClientModelId {
                        if let msg = ConfigModelPublicationSet(ctlTempPublication, to: model) {
                            groupConfigStatus = "Configuring CTL temp switch on \(nodeName)…"
                            logger.info("🔧 Configuring CTL switch client 0x\(String(model.modelId, radix: 16)) → 0xC002")
                            await sendConfig(msg, to: node)
                            try? await Task.sleep(for: .milliseconds(200))
                            completedOps += 1
                            groupConfigProgress = Double(completedOps) / Double(totalOps)
                        }
                    }
                }
            }
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeGroupConfigStates[idx].state = .completed
            }
        }

        // Bind app key and subscribe local provisioner models.
        // Element 0 (lighting servers) → main group; element 1 (CTL temp level) → CTL temp group.
        if let localNode {
            let localId = localNode.uuid
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == localId }) {
                nodeGroupConfigStates[idx].state = .inProgress
            }
            groupConfigStatus = "Configuring \(localName)…"
            let localElements = Array(localNode.elements)
            if !localElements.isEmpty {
                for model in localElements[0].models where localServerIds.contains(model.modelIdentifier) {
                    if let msg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                    if let msg = ConfigModelSubscriptionAdd(group: mainGroup, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                }
            }
            if localElements.count > 1 {
                for model in localElements[1].models where localCTLTempServerIds.contains(model.modelIdentifier) {
                    if let msg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                    if let msg = ConfigModelSubscriptionAdd(group: ctlTempGroup, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                }
            }
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == localId }) {
                nodeGroupConfigStates[idx].state = .completed
            }
        }

        groupConfigProgress = 1.0
        groupConfigStatus = "Done"

        _ = manager.save()

        let config = MeshGroupConfig(
            id: UUID().uuidString,
            name: name,
            groupAddress: mainGroupAddress,
            nodeUnicastAddresses: nodes.map { $0.primaryUnicastAddress },
            isOn: false,
            lightness: 0.5,
            temperature: 4000
        )
        currentGroup = config
        return config
    }

    // MARK: - Proxy Connection

    /// Scans for a GATT proxy node, connects, and waits until the bearer is open.
    func connectToProxy() async throws {
        guard manager.meshNetwork != nil else {
            throw AppError.networkNotReady
        }

        // Already connected – nothing to do
        if isConnectedToProxy { return }

        // Wait for Bluetooth to be ready (CBCentralManager starts as .unknown)
        if bluetoothState != .poweredOn {
            logger.info("Waiting for Bluetooth to power on...")
            for _ in 0..<50 { // up to 5 seconds
                try await Task.sleep(for: .milliseconds(100))
                if bluetoothState == .poweredOn { break }
            }
            guard bluetoothState == .poweredOn else {
                throw AppError.bluetoothUnavailable
            }
        }

        // Scan for proxy nodes
        scannerCentralManager.scanForPeripherals(
            withServices: [MeshProxyService.uuid],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("Scanning for proxy nodes...")

        // Wait until the proxy bearer is fully open (not just discovered)
        try await withCheckedThrowingContinuation { continuation in
            proxyConnectionContinuation = continuation
            Task {
                try? await Task.sleep(for: .seconds(15))
                await MainActor.run {
                    if let cont = self.proxyConnectionContinuation {
                        self.proxyConnectionContinuation = nil
                        self.scannerCentralManager.stopScan()
                        cont.resume(throwing: AppError.messageSendFailed(
                            "Proxy connection timed out"))
                    }
                }
            }
        }

        // Wait for the proxy filter handshake (Secure Network beacon → SetFilterType →
        // FilterStatus) to complete. Until FilterStatus is received, proxyFilter.proxy is
        // nil and the library logs a spurious "No GATT Proxy connected" warning on every
        // send. Up to 5 seconds; if the proxy is unusually slow we continue anyway.
        for _ in 0..<50 {
            if manager.proxyFilter.proxy != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    // MARK: - Light CTL Control

    func setOnOff(_ on: Bool) async throws {
        guard let group = currentGroup,
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No group or app key configured")
        }
        try await connectToProxy()
        let dest = MeshAddress(group.groupAddress)
        let message = GenericOnOffSetUnacknowledged(on)
        try? await manager.send(message, to: dest, using: appKey)
        currentGroup?.isOn = on
    }

    func setLightCTL(lightness: Double, temperature: UInt16) async throws {
        guard let group = currentGroup,
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No group or app key configured")
        }
        try await connectToProxy()
        let dest = MeshAddress(group.groupAddress)
        let lMin = currentGroup?.lightnessRangeMin ?? 0.01
        let lMax = currentGroup?.lightnessRangeMax ?? 1.0
        let clamped = lightness <= 0 ? 0.0 : max(lMin, min(lMax, lightness))
        let lightnessValue = UInt16(clamped * 65535)
        let rangeMin = currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
        let rangeMax = currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
        let clampedTemp = max(rangeMin, min(rangeMax, temperature))
        let transition = TransitionTime(steps: 2, stepResolution: .hundredsOfMilliseconds) // 200ms
        let message = LightCTLSetUnacknowledged(lightness: lightnessValue,
                                                temperature: clampedTemp,
                                                deltaUV: 0,
                                                transitionTime: transition,
                                                delay: 0)
        try? await manager.send(message, to: dest, using: appKey)
    }

    // MARK: - State Query

    /// Queries a provisioned node for its current on/off and CTL state,
    /// updating `currentGroup` to reflect the real device values.
    func fetchCurrentState() async {
        guard let node = provisionedNodes.first else { return }
        guard let appKey = manager.meshNetwork?.applicationKeys.first else { return }

        // Note: the proxy filter is configured as an empty reject list (= accept all) via
        // manager.proxyFilter.initialState, so we must NOT call proxyFilter.add() here.
        // Adding an address to a reject-list filter would BLOCK that address.

        // Bind the app key to local client models (persisted after first run)
        let localElement = manager.localElements.first
        let clientModelIds: [UInt16] = [.genericOnOffClientModelId, .lightCTLClientModelId]
        for modelId in clientModelIds {
            if let model = localElement?.model(withSigModelId: modelId),
               !model.boundApplicationKeys.contains(where: { $0.index == appKey.index }) {
                if let bind = ConfigModelAppBind(applicationKey: appKey, to: model) {
                    _ = try? await manager.sendToLocalNode(bind)
                }
            }
        }
        _ = manager.save()

        // Query GenericOnOff state from the first provisioned node
        if let onOffModel = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .genericOnOffServerModelId) }).first {
            do {
                let response = try await manager.send(GenericOnOffGet(), to: onOffModel)
                if let status = response as? GenericOnOffStatus {
                    logger.info("🔄 OnOff state: \(status.isOn ? "ON" : "OFF")")
                    currentGroup?.isOn = status.isOn
                }
            } catch {
                logger.warning("🔄 Failed to query OnOff state: \(error)")
            }
        }

        // Query LightCTL state
        if let ctlModel = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .lightCTLServerModelId) }).first {
            do {
                let response = try await manager.send(LightCTLGet(), to: ctlModel)
                if let status = response as? LightCTLStatus {
                    let lightness = Double(status.lightness) / 65535.0
                    logger.info("🔄 CTL state: lightness=\(Int(lightness * 100))%, temp=\(status.temperature)K")
                    currentGroup?.lightness = lightness
                    currentGroup?.temperature = status.temperature
                }
            } catch {
                logger.warning("🔄 Failed to query CTL state: \(error)")
            }
        }

        // Query Light Lightness range
        if let lightnessServer = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .lightLightnessServerModelId) }).first {
            do {
                let response = try await manager.send(LightLightnessRangeGet(), to: lightnessServer)
                if let status = response as? LightLightnessRangeStatus, status.min > 0 {
                    let rMin = Double(status.min) / 65535.0
                    let rMax = Double(status.max) / 65535.0
                    logger.info("🔄 Lightness range: \(Int(rMin * 100))%–\(Int(rMax * 100))%")
                    currentGroup?.lightnessRangeMin = rMin
                    currentGroup?.lightnessRangeMax = rMax
                    if let l = currentGroup?.lightness {
                        currentGroup?.lightness = max(rMin, min(rMax, l))
                    }
                }
            } catch {
                logger.warning("🔄 Failed to query lightness range: \(error)")
            }
        }

        // Query LightCTL temperature range (sent to CTL Server, same as LightCTLGet)
        if let ctlServerForRange = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .lightCTLServerModelId) }).first {
            do {
                let response = try await manager.send(LightCTLTemperatureRangeGet(), to: ctlServerForRange)
                if let status = response as? LightCTLTemperatureRangeStatus {
                    logger.info("🔄 CTL temperature range: \(status.min)K–\(status.max)K")
                    currentGroup?.temperatureRangeMin = status.min
                    currentGroup?.temperatureRangeMax = status.max
                    // Clamp current temperature to new range
                    if let temp = currentGroup?.temperature {
                        currentGroup?.temperature = max(status.min, min(status.max, temp))
                    }
                }
            } catch {
                logger.warning("🔄 Failed to query CTL temperature range: \(error)")
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MeshNetworkService: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            bluetoothState = central.state
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                     didDiscover peripheral: CBPeripheral,
                                     advertisementData: [String: Any],
                                     rssi RSSI: NSNumber) {
        // Extract all needed values from non-Sendable advertisementData before Task boundary
        let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]
        let hasServiceData = serviceData != nil
        let meshData = serviceData?[MeshProvisioningService.uuid]
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let rssiValue = RSSI.intValue

        Task { @MainActor in
            // Proxy discovery – connect but don't resume until bearer is open
            if proxyConnectionContinuation != nil, hasServiceData {
                central.stopScan()
                connectToProxyPeripheral(peripheral)
                return
            }

            // Provisioning scan
            guard let meshData, meshData.count >= 16 else { return }

            // Parse device UUID from first 16 bytes of service data
            let uuidBytes = Array(meshData.prefix(16))
            guard let deviceUUID = UUID(uuidBytes: uuidBytes) else { return }
            guard !discoveredDevices.contains(where: { $0.id == deviceUUID }) else { return }

            discoveredPeripheralMeshData[peripheral.identifier] = meshData
            peripheralIDToDeviceID[peripheral.identifier] = deviceUUID

            let name = peripheral.name ?? localName ?? "Mesh Light"
            let device = DiscoveredDevice(
                id: deviceUUID,
                name: name,
                rssi: rssiValue,
                peripheral: peripheral,
                advertisementData: meshData
            )
            discoveredDevices.append(device)
            logger.info("Discovered: \(name) [\(deviceUUID)]")
        }
    }

    @MainActor
    private func connectToProxyPeripheral(_ peripheral: CBPeripheral) {
        logger.info("🔌 Connecting to proxy peripheral: \(peripheral.identifier)")
        let bearer = GattBearer(targetWithIdentifier: peripheral.identifier)
        bearer.logger = self
        bearer.delegate = self
        bearer.dataDelegate = manager
        proxyBearer = bearer
        manager.transmitter = bearer
        logger.info("🔌 Bearer delegate: \(bearer.delegate != nil), dataDelegate: \(bearer.dataDelegate != nil), transmitter: \(self.manager.transmitter != nil)")
        bearer.open()
        logger.info("🔌 Bearer.open() called")
    }
}

// MARK: - BearerDelegate (for proxy GattBearer)

extension MeshNetworkService: BearerDelegate {
    nonisolated func bearerDidOpen(_ bearer: Bearer) {
        Task { @MainActor in
            if bearer === proxyBearer {
                isConnectedToProxy = true
                logger.info("🟢 Proxy bearer OPENED — bearer type: \(type(of: bearer)), transmitter set: \(self.manager.transmitter != nil)")
                if let cont = proxyConnectionContinuation {
                    proxyConnectionContinuation = nil
                    cont.resume()
                }
            } else {
                logger.info("🟢 Bearer opened but NOT proxy bearer (type: \(type(of: bearer)))")
            }
        }
    }

    nonisolated func bearer(_ bearer: Bearer, didClose error: Error?) {
        Task { @MainActor in
            if bearer === proxyBearer {
                isConnectedToProxy = false
                proxyBearer = nil
                manager.transmitter = nil
                logger.info("🔴 Proxy bearer CLOSED — error: \(error?.localizedDescription ?? "none")")
                // If we were still waiting on connection, report the failure
                if let cont = proxyConnectionContinuation {
                    proxyConnectionContinuation = nil
                    cont.resume(throwing: error ?? AppError.messageSendFailed(
                        "Proxy connection closed"))
                } else if hasProvisionedNetwork {
                    // Auto-reconnect if we have a provisioned network
                    logger.info("Auto-reconnecting to proxy...")
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        try? await connectToProxy()
                    }
                }
            }
        }
    }
}

// MARK: - ProvisioningDelegate

extension MeshNetworkService: ProvisioningDelegate {

    nonisolated func provisioningState(of device: UnprovisionedDevice,
                                        didChangeTo state: ProvisioningState) {
        Task { @MainActor in
            let id = device.uuid
            switch state {
            case .requestingCapabilities:
                provisioningStates[id] = .inProgress(progress: 0.2)
            case .capabilitiesReceived:
                provisioningStates[id] = .inProgress(progress: 0.4)
                guard let pm = activeProvisioningManagers[id] else { break }
                do {
                    try pm.provision(
                        usingAlgorithm: .BTM_ECDH_P256_CMAC_AES128_AES_CCM,
                        publicKey: .noOobPublicKey,
                        authenticationMethod: .noOob
                    )
                } catch {
                    finishProvisioning(id: id, result: .failure(error))
                }
            case .provisioning:
                provisioningStates[id] = .inProgress(progress: 0.7)
            case .complete:
                provisioningStates[id] = .inProgress(progress: 1.0)
                // The node was added to the network – find it
                if let node = manager.meshNetwork?.node(withUuid: device.uuid) {
                    finishProvisioning(id: id, result: .success(node))
                } else {
                    // Try to find the last added node
                    if let node = manager.meshNetwork?.nodes.last {
                        finishProvisioning(id: id, result: .success(node))
                    } else {
                        finishProvisioning(id: id, result: .failure(
                            AppError.provisioningFailed("Node not found after provisioning")))
                    }
                }
            case .failed(let error):
                finishProvisioning(id: id,
                                   result: .failure(AppError.provisioningFailed(error.localizedDescription)))
            default:
                break
            }
        }
    }

    nonisolated func authenticationActionRequired(_ action: AuthAction) {
        // noOob auth - nothing to do
        logger.debug("Auth action required: \(String(describing: action))")
    }

    nonisolated func inputComplete() {
        // Called after user input for inputOob - not used with noOob
    }
}

// MARK: - MeshNetworkDelegate

extension MeshNetworkService: MeshNetworkDelegate {
    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         didReceiveMessage message: MeshMessage,
                                         sentFrom source: Address,
                                         to destination: MeshAddress) {
        // Resolve any config continuation waiting for this opCode from this node.
        // Must happen before the loopback guard — local node config responses have
        // source == provisioner address and would otherwise be silently dropped.
        let configKey = ConfigContinuationKey(sourceAddress: source, responseOpCode: message.opCode)
        Task { @MainActor in
            if let cont = pendingConfigContinuations.removeValue(forKey: configKey) {
                cont.resume()
            }
        }

        // Ignore loopback — messages we sent to a group that echo back via the proxy filter.
        // Config responses are already handled above so this only suppresses state updates.
        guard source != manager.meshNetwork?.localProvisioner?.primaryUnicastAddress else { return }
        logger.info("📩 RECEIVED \(type(of: message)) opCode=0x\(String(message.opCode, radix: 16)) from 0x\(String(source, radix: 16)) to 0x\(String(destination.address, radix: 16))")
        if message is ConfigCompositionDataStatus {
            logger.info("📩 Got composition data response!")
        }
        if let status = message as? ConfigStatusMessage {
            logger.info("📩 Config status: \(status.isSuccess ? "success" : "failed"): \(status.message)")
        }
        // Update group state from incoming commands (switch) and status responses.
        Task { @MainActor in
            switch message {
            case let cmd as GenericOnOffSetUnacknowledged:
                logger.info("🔄 OnOff command received: \(cmd.isOn ? "ON" : "OFF")")
                self.currentGroup?.isOn = cmd.isOn

            case let status as GenericOnOffStatus:
                logger.info("🔄 OnOff state: \(status.isOn ? "ON" : "OFF")")
                self.currentGroup?.isOn = status.isOn

            case let cmd as GenericLevelSet:
                if destination.address == 0xC002 {
                    // Second Silvair controller → colour temperature
                    let tMin = self.currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
                    let tMax = self.currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
                    let normalized = (Double(cmd.level) + 32768.0) / 65535.0
                    let temp = tMin + UInt16(normalized * Double(tMax - tMin))
                    logger.info("🌡️ CTL level command (second controller): \(cmd.level) → \(temp)K")
                    self.currentGroup?.temperature = temp
                } else {
                    let lightnessRaw = UInt16(Int32(cmd.level) + 32768)
                    let lightness = Double(lightnessRaw) / 65535.0
                    logger.info("🔄 Level command received: \(cmd.level) → lightness=\(Int(lightness * 100))%")
                    self.currentGroup?.lightness = lightness
                    if lightnessRaw == 0 { self.currentGroup?.isOn = false }
                    else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }
                }

            case let cmd as GenericLevelSetUnacknowledged:
                if destination.address == 0xC002 {
                    let tMin = self.currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
                    let tMax = self.currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
                    let normalized = (Double(cmd.level) + 32768.0) / 65535.0
                    let temp = tMin + UInt16(normalized * Double(tMax - tMin))
                    logger.info("🌡️ CTL level command (second controller): \(cmd.level) → \(temp)K")
                    self.currentGroup?.temperature = temp
                } else {
                    let lightnessRaw = UInt16(Int32(cmd.level) + 32768)
                    let lightness = Double(lightnessRaw) / 65535.0
                    logger.info("🔄 Level command received: \(cmd.level) → lightness=\(Int(lightness * 100))%")
                    self.currentGroup?.lightness = lightness
                    if lightnessRaw == 0 { self.currentGroup?.isOn = false }
                    else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }
                }

            case let cmd as GenericDeltaSetUnacknowledged:
                if destination.address == 0xC002 {
                    // Delta from second Silvair controller → colour temperature change
                    let tMin = self.currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
                    let tMax = self.currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
                    let currentTemp = self.currentGroup?.temperature ?? UInt16((Double(tMin) + Double(tMax)) / 2.0)
                    let tempFraction = tMax > tMin
                        ? max(0.0, min(1.0, Double(Int(currentTemp) - Int(tMin)) / Double(Int(tMax) - Int(tMin))))
                        : 0.5
                    let currentLevel = Int32(tempFraction * 65535.0) - 32768
                    let newLevel = max(-32768, min(32767, currentLevel + cmd.delta))
                    let newFraction = (Double(newLevel) + 32768.0) / 65535.0
                    let temp = tMin + UInt16(newFraction * Double(tMax - tMin))
                    logger.info("🌡️ CTL delta command (second controller): Δ\(cmd.delta) → \(temp)K")
                    self.currentGroup?.temperature = temp
                } else {
                    let currentLevel = Int32((self.currentGroup?.lightness ?? 0.5) * 65535) - 32768
                    let newLevel = max(-32768, min(32767, currentLevel + cmd.delta))
                    let lightnessRaw = UInt16(newLevel + 32768)
                    let lightness = Double(lightnessRaw) / 65535.0
                    logger.info("🔄 Delta command received: Δ\(cmd.delta) → level=\(newLevel), lightness=\(Int(lightness * 100))%")
                    self.currentGroup?.lightness = lightness
                    if lightnessRaw == 0 { self.currentGroup?.isOn = false }
                    else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }
                }

            case let status as GenericLevelStatus:
                let lightnessRaw = UInt16(Int32(status.level) + 32768)
                let lightness = Double(lightnessRaw) / 65535.0
                logger.info("🔄 Level status received: \(status.level) → lightness=\(Int(lightness * 100))%")
                self.currentGroup?.lightness = lightness

            case let cmd as LightLightnessSetUnacknowledged:
                let lightness = Double(cmd.lightness) / 65535.0
                logger.info("🔄 Lightness command received: lightness=\(Int(lightness * 100))%")
                self.currentGroup?.lightness = lightness
                if cmd.lightness == 0 { self.currentGroup?.isOn = false }
                else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }

            case let status as LightLightnessStatus:
                let lightness = Double(status.lightness) / 65535.0
                logger.info("🔄 Lightness status received: lightness=\(Int(lightness * 100))%")
                self.currentGroup?.lightness = lightness

            case let cmd as LightCTLSetUnacknowledged:
                let lightness = Double(cmd.lightness) / 65535.0
                logger.info("🔄 CTL command received: lightness=\(Int(lightness * 100))%, temp=\(cmd.temperature)K")
                self.currentGroup?.lightness = lightness
                self.currentGroup?.temperature = cmd.temperature

            case let status as LightCTLStatus:
                let lightness = Double(status.lightness) / 65535.0
                logger.info("🔄 CTL state: lightness=\(Int(lightness * 100))%, temp=\(status.temperature)K")
                self.currentGroup?.lightness = lightness
                self.currentGroup?.temperature = status.temperature

            case let status as LightCTLTemperatureRangeStatus:
                logger.info("🔄 CTL temperature range: \(status.min)K–\(status.max)K")
                self.currentGroup?.temperatureRangeMin = status.min
                self.currentGroup?.temperatureRangeMax = status.max
                if let temp = self.currentGroup?.temperature {
                    self.currentGroup?.temperature = max(status.min, min(status.max, temp))
                }

            case let status as LightLightnessRangeStatus where status.min > 0:
                let rMin = Double(status.min) / 65535.0
                let rMax = Double(status.max) / 65535.0
                logger.info("🔄 Lightness range: \(Int(rMin * 100))%–\(Int(rMax * 100))%")
                self.currentGroup?.lightnessRangeMin = rMin
                self.currentGroup?.lightnessRangeMax = rMax
                if let l = self.currentGroup?.lightness {
                    self.currentGroup?.lightness = max(rMin, min(rMax, l))
                }

            default:
                break
            }
        }
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         didSendMessage message: MeshMessage,
                                         from localElement: Element,
                                         to destination: MeshAddress) {
        logger.info("📤 SENT \(type(of: message)) to 0x\(String(destination.address, radix: 16))")
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         failedToSendMessage message: MeshMessage,
                                         from localElement: Element,
                                         to destination: MeshAddress,
                                         error: Error) {
        logger.error("❌ FAILED to send \(type(of: message)) to 0x\(String(destination.address, radix: 16)): \(error)")
    }
}

// MARK: - LoggerDelegate

extension MeshNetworkService: LoggerDelegate {
    nonisolated func log(message: String, ofCategory category: LogCategory, withLevel level: LogLevel) {
        switch level {
        case .error:   logger.error("[\(category.rawValue)] \(message)")
        case .warning: logger.warning("[\(category.rawValue)] \(message)")
        case .info:    logger.info("[\(category.rawValue)] \(message)")
        default:       logger.debug("[\(category.rawValue)] \(message)")
        }
    }
}

// MARK: - UUID from raw bytes

private extension UUID {
    init?(uuidBytes: [UInt8]) {
        guard uuidBytes.count >= 16 else { return nil }
        self = NSUUID(uuidBytes: uuidBytes) as UUID
    }
}

// MARK: - ProvisioningBearerBridge

/// Bridges BearerDelegate callbacks to closures so each provisioning bearer
/// can notify its device independently.
private final class ProvisioningBearerBridge: NSObject, BearerDelegate {
    let deviceID: UUID
    weak var provisioningManager: ProvisioningManager?
    let onOpen: () -> Void
    let onClose: (Error?) -> Void

    init(deviceID: UUID, provisioningManager: ProvisioningManager,
         onOpen: @escaping () -> Void,
         onClose: @escaping (Error?) -> Void) {
        self.deviceID = deviceID
        self.provisioningManager = provisioningManager
        self.onOpen = onOpen
        self.onClose = onClose
    }

    func bearerDidOpen(_ bearer: Bearer) { onOpen() }
    func bearer(_ bearer: Bearer, didClose error: Error?) { onClose(error) }
}
// MARK: - OnceGate

/// Thread-safe gate that allows only the first caller through.
/// Used to ensure a continuation is resumed exactly once in a race between
/// an operation completing and a timeout firing.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    func tryPass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !passed else { return false }
        passed = true
        return true
    }
}

// MARK: - ConfigContinuationKey

private struct ConfigContinuationKey: Hashable {
    let sourceAddress: UInt16
    let responseOpCode: UInt32
}

// MARK: - LightControlClientDelegate

/// Model delegate for local GenericOnOff Client and LightCTL Client models.
/// Registers the response opcodes so the library decodes status messages
/// instead of returning UnknownMessage.
private class LightControlClientDelegate: ModelDelegate {
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
private class LightServerDelegate: ModelDelegate {
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
