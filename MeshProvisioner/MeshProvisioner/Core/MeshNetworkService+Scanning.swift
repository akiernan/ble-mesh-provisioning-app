@preconcurrency import CoreBluetooth
@preconcurrency import NordicMesh

// MARK: - Scanning

extension MeshNetworkService {

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
}

// MARK: - UUID from raw bytes

private extension UUID {
    init?(uuidBytes: [UInt8]) {
        guard uuidBytes.count >= 16 else { return nil }
        self = NSUUID(uuidBytes: uuidBytes) as UUID
    }
}
