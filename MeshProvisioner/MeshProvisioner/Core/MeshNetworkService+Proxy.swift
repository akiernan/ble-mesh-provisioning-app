@preconcurrency import CoreBluetooth
@preconcurrency import NordicMesh

// MARK: - Proxy Connection

extension MeshNetworkService {

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

        // Bind local client models to the app key so the library can route incoming
        // app-key-encrypted messages without generating "[Model] ... not bound to key" warnings.
        await bindLocalClientModelsIfNeeded()
        _ = manager.save()
    }

    @MainActor
    func connectToProxyPeripheral(_ peripheral: CBPeripheral) {
        // Cancel any lingering connection for the same reason as provisioning —
        // forces a fresh GATT discovery on reconnect if the device changed mode.
        scannerCentralManager.cancelPeripheralConnection(peripheral)
        proxyNodeName = peripheral.name
        logger.info("🔌 Connecting to proxy peripheral: \(peripheral.identifier)")
        let bearer = GattBearer(target: peripheral)
        bearer.logger = self
        bearer.delegate = self
        bearer.dataDelegate = manager
        proxyBearer = bearer
        manager.transmitter = bearer
        bearer.open()
    }
}

// MARK: - BearerDelegate (for proxy GattBearer)

extension MeshNetworkService: BearerDelegate {

    nonisolated func bearerDidOpen(_ bearer: Bearer) {
        Task { @MainActor in
            if bearer === proxyBearer {
                isConnectedToProxy = true
                logger.info("🟢 Proxy bearer opened")
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
                proxyNodeName = nil
                manager.transmitter = nil
                logger.info("🔴 Proxy bearer CLOSED — error: \(error?.localizedDescription ?? "none")")
                // If we were still waiting on connection, report the failure
                if let cont = proxyConnectionContinuation {
                    proxyConnectionContinuation = nil
                    cont.resume(throwing: error ?? AppError.messageSendFailed(
                        "Proxy connection closed"))
                } else if hasProvisionedNetwork && !suppressAutoReconnect {
                    // Auto-reconnect if we have a provisioned network, then refresh state
                    logger.info("Auto-reconnecting to proxy...")
                    Task {
                        try? await Task.sleep(for: .seconds(1))
                        try? await connectToProxy()
                        await fetchCurrentState()
                    }
                }
            }
        }
    }
}
