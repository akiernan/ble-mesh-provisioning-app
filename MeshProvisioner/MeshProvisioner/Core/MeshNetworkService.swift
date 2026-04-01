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

    // MARK: Selection State (shared between screens)

    var selectedDevicesForProvisioning: [DiscoveredDevice] = []
    var provisionedNodes: [Node] = []

    // MARK: Private

    private let manager: MeshNetworkManager
    private var scannerCentralManager: CBCentralManager!

    // Provisioning helpers – each device gets its own PBGattBearer (own central manager)
    private var activeProvisioningManagers: [UUID: ProvisioningManager] = [:]
    private var provisioningContinuations: [UUID: CheckedContinuation<Node, Error>] = [:]
    // Strong reference to bearer delegates – PBGattBearer.delegate is weak
    private var activeBearerDelegates: [UUID: ProvisioningBearerBridge] = [:]

    // Peripheral UUID → device UUID mapping (for scanning results)
    private var peripheralIDToDeviceID: [UUID: UUID] = [:]
    private var discoveredPeripheralMeshData: [UUID: Data] = [:]

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
                let netKey = try network.add(
                    networkKey: Data.random128BitKey(),
                    withIndex: 0,
                    name: "Primary Network Key"
                )
                let appKey = try network.add(
                    applicationKey: Data.random128BitKey(),
                    withIndex: 0,
                    name: "Light CTL App Key"
                )
                try appKey.bind(to: netKey)
            }
            _ = manager.save()
        } catch {
            self.error = error
            logger.error("Failed to set up mesh network: \(error)")
        }
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
                try bearer.open()
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

        // Step 2: Distribute keys – send ConfigAppKeyAdd to each node
        keyBindingStepStates[.distributeKeys] = .inProgress
        for node in nodes {
            let request = ConfigAppKeyAdd(applicationKey: appKey)
            await withTimeout { [manager] in _ = try await manager.send(request, to: node) }
            try? await Task.sleep(for: .milliseconds(200))
        }
        keyBindingStepStates[.distributeKeys] = .completed

        // Step 3: Configure LightCTL model binding on each node
        keyBindingStepStates[.configureModels] = .inProgress
        for node in nodes {
            for element in node.elements {
                if let model = element.model(withSigModelId: SIGModelID.lightCTLServer) {
                    if let bindMsg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        await withTimeout { [manager] in _ = try await manager.send(bindMsg, to: node) }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                // Also bind GenericOnOff for on/off control
                if let model = element.model(withSigModelId: SIGModelID.genericOnOffServer) {
                    if let bindMsg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        await withTimeout { [manager] in _ = try await manager.send(bindMsg, to: node) }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
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

        let groupAddress: Address = 0xC001
        let group: Group
        if let existing = network.group(withAddress: MeshAddress(groupAddress)) {
            group = existing
        } else {
            do {
                group = try Group(name: name, address: MeshAddress(groupAddress))
                try network.add(group: group)
            } catch {
                throw AppError.groupConfigFailed(error.localizedDescription)
            }
        }

        // Subscribe each node's CTL + OnOff models to the group
        for node in nodes {
            for element in node.elements {
                let modelIDs: [UInt16] = [SIGModelID.lightCTLServer, SIGModelID.genericOnOffServer]
                for modelID in modelIDs {
                    if let model = element.model(withSigModelId: modelID),
                       let msg = ConfigModelSubscriptionAdd(group: group, to: model) {
                        await withTimeout { [manager] in _ = try await manager.send(msg, to: node) }
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
            }
        }

        _ = manager.save()

        let config = MeshGroupConfig(
            id: UUID().uuidString,
            name: name,
            groupAddress: groupAddress,
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
        guard bluetoothState == .poweredOn else {
            throw AppError.bluetoothUnavailable
        }
        guard manager.meshNetwork != nil else {
            throw AppError.networkNotReady
        }

        // Already connected – nothing to do
        if isConnectedToProxy { return }

        // Give the device time to transition from provisioning to proxy mode
        // and for the old PB-GATT bearer to fully close before we connect.
        try await Task.sleep(for: .seconds(2))

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
    }

    // MARK: - Light CTL Control

    func setOnOff(_ on: Bool) throws {
        guard let group = currentGroup,
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No group or app key configured")
        }
        let dest = MeshAddress(group.groupAddress)
        let message = GenericOnOffSetUnacknowledged(on)
        Task {
            try? await manager.send(message, to: dest, using: appKey)
        }
        currentGroup?.isOn = on
    }

    func setLightCTL(lightness: Double, temperature: UInt16) throws {
        guard let group = currentGroup,
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No group or app key configured")
        }
        let dest = MeshAddress(group.groupAddress)
        let lightnessValue = UInt16(max(0.0, min(1.0, lightness)) * 65535)
        let clampedTemp = max(MeshGroupConfig.temperatureMin,
                              min(MeshGroupConfig.temperatureMax, temperature))
        let message = LightCTLSetUnacknowledged(lightness: lightnessValue,
                                                temperature: clampedTemp,
                                                deltaUV: 0)
        Task {
            try? await manager.send(message, to: dest, using: appKey)
        }
        currentGroup?.lightness = lightness
        currentGroup?.temperature = temperature
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
        let bearer = GattBearer(targetWithIdentifier: peripheral.identifier)
        bearer.logger = self
        bearer.delegate = self
        bearer.dataDelegate = manager
        proxyBearer = bearer
        manager.transmitter = bearer
        do {
            try bearer.open()
        } catch {
            logger.error("Failed to open proxy bearer: \(error)")
        }
    }
}

// MARK: - BearerDelegate (for proxy GattBearer)

extension MeshNetworkService: BearerDelegate {
    nonisolated func bearerDidOpen(_ bearer: Bearer) {
        Task { @MainActor in
            if bearer === proxyBearer {
                isConnectedToProxy = true
                logger.info("Connected to proxy")
                if let cont = proxyConnectionContinuation {
                    proxyConnectionContinuation = nil
                    cont.resume()
                }
            }
        }
    }

    nonisolated func bearer(_ bearer: Bearer, didClose error: Error?) {
        Task { @MainActor in
            if bearer === proxyBearer {
                isConnectedToProxy = false
                proxyBearer = nil
                manager.transmitter = nil
                logger.info("Proxy disconnected")
                // If we were still waiting on connection, report the failure
                if let cont = proxyConnectionContinuation {
                    proxyConnectionContinuation = nil
                    cont.resume(throwing: error ?? AppError.messageSendFailed(
                        "Proxy connection closed"))
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
                        usingAlgorithm: .fipsP256EllipticCurve,
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
        // Handle status responses if needed
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         didSendMessage message: MeshMessage,
                                         from localElement: Element,
                                         to destination: MeshAddress) {
        // Sent confirmation
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         failedToSendMessage message: MeshMessage,
                                         from localElement: Element,
                                         to destination: MeshAddress,
                                         error: Error) {
        logger.error("Failed to send: \(error)")
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

