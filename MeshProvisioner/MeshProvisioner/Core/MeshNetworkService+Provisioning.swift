@preconcurrency import CoreBluetooth
@preconcurrency import NordicMesh

// MARK: - Provisioning

extension MeshNetworkService {

    /// Provisions a single device. Returns the provisioned Node on success.
    ///
    /// We pass the raw `CBPeripheral` from the scan callback directly to
    /// `PBGattBearer(target:)`, matching the Nordic example app's approach.
    /// Using `PBGattBearer(targetWithIdentifier:)` instead causes the bearer's
    /// fresh internal `CBCentralManager` to call `retrievePeripherals`, which
    /// rehydrates the peripheral with the daemon's stale GATT cache — the root
    /// cause of "Device not supported" after a factory reset or SMP session
    /// (nordicsemi/IOS-nRF-Mesh-Library#289).
    func provisionDevice(_ device: DiscoveredDevice) async throws -> Node {
        return try await provisionWithPeripheral(device: device, peripheral: device.peripheral)
    }

    func provisionWithPeripheral(device: DiscoveredDevice,
                                 peripheral: CBPeripheral) async throws -> Node {
        guard manager.meshNetwork != nil else { throw AppError.networkNotReady }

        let storedMeshData = discoveredPeripheralMeshData[device.peripheral.identifier]
        let unprovisionedDevice = UnprovisionedDevice(
            name: device.name,
            uuid: device.id,
            oobInformation: oobInfo(from: storedMeshData)
        )

        return try await withCheckedThrowingContinuation { continuation in
            let bearer = PBGattBearer(target: peripheral)
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

    func handleBearerDidOpen(deviceID: UUID, pm: ProvisioningManager) {
        do {
            try pm.identify(andAttractFor: 0)
        } catch {
            finishProvisioning(id: deviceID,
                               result: .failure(AppError.provisioningFailed(error.localizedDescription)))
        }
    }

    func oobInfo(from meshData: Data?) -> OobInformation {
        if let meshData, meshData.count >= 18 {
            return OobInformation(rawValue: UInt16(meshData[16]) | (UInt16(meshData[17]) << 8))
        }
        return OobInformation(rawValue: 0)
    }

    @MainActor
    func finishProvisioning(id: UUID, result: Result<Node, Error>) {
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

// MARK: - ProvisioningBearerBridge

/// Bridges BearerDelegate callbacks to closures so each provisioning bearer
/// can notify its device independently.
final class ProvisioningBearerBridge: NSObject, BearerDelegate {
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
