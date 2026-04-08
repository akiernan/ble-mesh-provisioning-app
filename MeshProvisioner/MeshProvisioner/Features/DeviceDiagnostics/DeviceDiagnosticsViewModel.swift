import Foundation
import CoreBluetooth
import CryptoKit
import os.log
import iOSMcuManagerLibrary

private let diagLogger = Logger(subsystem: "uk.a-squared-projects.MeshProvisioner", category: "DeviceDiagnostics")

// MARK: - Supporting Types

struct ImageSlotInfo: Identifiable {
    var id: Int { slot }
    let slot: Int
    let version: String
    let active: Bool
    let pending: Bool
    let confirmed: Bool
}

enum DiagnosticsError: LocalizedError {
    case deviceNotFound
    case notConnected
    case cancelled

    var errorDescription: String? {
        switch self {
        case .deviceNotFound: return "Device not found — ensure it is advertising"
        case .notConnected: return "Not connected to device"
        case .cancelled: return "OTA cancelled"
        }
    }
}

// MARK: - DeviceDiagnosticsViewModel

@Observable
@MainActor
final class DeviceDiagnosticsViewModel: NSObject {

    // MARK: Input

    let nodeName: String
    let unicastAddress: UInt16

    // MARK: Observed State

    enum ConnectionState {
        case idle, scanning, connecting, connected, failed(String)
    }
    enum Operation {
        case none, fetchingInfo, resettingToBootloader, softResetting
        case uploading(progress: Double), reconnecting
    }

    var connectionState: ConnectionState = .idle
    var currentOperation: Operation = .none
    var errorMessage: String?

    // MARK: Results

    struct AppInfo {
        let project: String
        let version: String
        let idfVersion: String
        let chip: String
        let buildDate: String
    }
    var appInfo: AppInfo?
    var imageSlots: [ImageSlotInfo] = []

    // MARK: Private

    private let meshService: MeshNetworkService
    private var smpCentralManager: CBCentralManager?
    private var scanContinuation: CheckedContinuation<UUID, Error>?
    private var transport: McuMgrBleTransport?
    private var defaultManager: DefaultManager?
    private var imageManager: ImageManager?
    private var firmwareUpgradeManager: FirmwareUpgradeManager?
    private var upgradeContinuation: CheckedContinuation<Void, Error>?

    // MARK: Init

    init(unicastAddress: UInt16, meshService: MeshNetworkService) {
        self.unicastAddress = unicastAddress
        self.meshService = meshService
        self.nodeName = meshService.provisionedNodes
            .first { $0.primaryUnicastAddress == unicastAddress }?
            .name ?? "Mesh Node"
        super.init()
        diagLogger.info("Init — node: \(self.nodeName, privacy: .public), unicast: 0x\(String(format: "%04X", unicastAddress), privacy: .public)")
    }

    // MARK: - Connection

    func connect() async {
        switch connectionState {
        case .scanning, .connecting, .connected: return
        default: break
        }
        diagLogger.info("Connecting to '\(self.nodeName, privacy: .public)'")
        connectionState = .scanning
        errorMessage = nil

        do {
            let uuid = try await scanForDevice()
            connectionState = .connecting
            let t = McuMgrBleTransport(uuid)
            // The mesh proxy (and this ESP32) fixes ATT MTU at 20 bytes.
            // Enabling chunking splits outgoing SMP frames into ≤20-byte BLE writes;
            // the device's SMP layer reassembles them before processing.
            t.chunkSendDataToMtuSize = true
            self.transport = t
            self.defaultManager = DefaultManager(transport: t)
            self.imageManager = ImageManager(transport: t)
            connectionState = .connected
            diagLogger.info("Connected — \(uuid, privacy: .public)")
        } catch {
            diagLogger.error("connect() failed: \(error.localizedDescription, privacy: .public)")
            connectionState = .failed(error.localizedDescription)
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        smpCentralManager?.stopScan()
        smpCentralManager = nil
        transport?.close()
        transport = nil
        defaultManager = nil
        imageManager = nil
        firmwareUpgradeManager = nil
        connectionState = .idle
    }

    // MARK: - SMP Operations

    func fetchInfo() async {
        guard let dm = defaultManager, let im = imageManager else {
            diagLogger.warning("fetchInfo() — not connected")
            errorMessage = DiagnosticsError.notConnected.localizedDescription
            return
        }
        diagLogger.info("fetchInfo()")
        currentOperation = .fetchingInfo
        errorMessage = nil

        // One request per field — applicationInfo(format:) takes a Set whose iteration
        // order is non-deterministic, so a multi-field request produces an unordered
        // space-separated string that can't be parsed reliably. Single-element Sets have
        // no ordering ambiguity. Continuations resume directly from the McuManager
        // callback thread; only Sendable String values cross the actor boundary.
        func fetchField(_ format: DefaultManager.ApplicationInfoFormat) async -> String {
            await withCheckedContinuation { cont in
                dm.applicationInfo(format: [format]) { response, error in
                    if let error {
                        diagLogger.error("app_info(\(format.rawValue, privacy: .public)) error: \(error.localizedDescription, privacy: .public)")
                    }
                    cont.resume(returning: response?.response?.trimmingCharacters(in: .whitespaces) ?? "—")
                }
            }
        }

        let project   = await fetchField(.nodeName)
        let version   = await fetchField(.kernelVersion)
        let idfVer    = await fetchField(.kernelRelease)
        let chip      = await fetchField(.machine)
        let buildDate = await fetchField(.buildDateTime)
        appInfo = AppInfo(project: project, version: version, idfVersion: idfVer, chip: chip, buildDate: buildDate)
        diagLogger.info("app_info — project: \(project, privacy: .public), version: \(version, privacy: .public), idf: \(idfVer, privacy: .public), chip: \(chip, privacy: .public), built: \(buildDate, privacy: .public)")

        imageSlots = await withCheckedContinuation { cont in
            im.list { response, error in
                if let error {
                    diagLogger.error("image list error: \(error.localizedDescription, privacy: .public)")
                }
                let slots = (response?.images ?? []).map { slot in
                    ImageSlotInfo(
                        slot: Int(slot.slot),
                        version: slot.version ?? "—",
                        active: slot.active,
                        pending: slot.pending,
                        confirmed: slot.confirmed
                    )
                }
                cont.resume(returning: slots)
            }
        }

        diagLogger.info("fetchInfo() done — slots: \(self.imageSlots.count)")
        currentOperation = .none
    }

    func softReset() async {
        guard let dm = defaultManager else {
            diagLogger.warning("softReset() — not connected")
            errorMessage = DiagnosticsError.notConnected.localizedDescription
            return
        }
        diagLogger.info("softReset() — sending reset(bootMode: .normal)")
        currentOperation = .softResetting
        errorMessage = nil

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dm.reset(bootMode: .normal) { _, error in
                if let error { diagLogger.error("softReset error: \(error.localizedDescription, privacy: .public)") }
                Task { @MainActor in cont.resume() }
            }
        }

        disconnect()
        currentOperation = .reconnecting
        // Normal-mode boot (full ESP-IDF + mesh stack) takes longer than bootloader.
        try? await Task.sleep(for: .milliseconds(3000))
        try? await meshService.connectToProxy()
        diagLogger.info("softReset() done — proxy reconnected")
        currentOperation = .none
    }

    func resetToBootloader() async {
        guard let dm = defaultManager else {
            diagLogger.warning("resetToBootloader() — not connected")
            errorMessage = DiagnosticsError.notConnected.localizedDescription
            return
        }
        diagLogger.info("resetToBootloader() — sending reset(bootMode: .bootloader)")
        currentOperation = .resettingToBootloader
        errorMessage = nil

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            dm.reset(bootMode: .bootloader) { _, error in
                if let error { diagLogger.error("resetToBootloader error: \(error.localizedDescription, privacy: .public)") }
                Task { @MainActor in cont.resume() }
            }
        }

        diagLogger.info("resetToBootloader() done — waiting for device to enter DFU mode")
        disconnect()
        // Give the device time to reboot into bootloader before scanning.
        // The device advertises as "DFU:<nodeName>"; scanForDevice() strips the prefix.
        try? await Task.sleep(for: .milliseconds(1500))
        await connect()
        currentOperation = .none
    }

    func startOTAViaBootloader(data: Data) async {
        await resetToBootloader()
        await startOTA(data: data)
    }

    func startOTA(data: Data) async {
        diagLogger.info("startOTA() — \(data.count) bytes")
        currentOperation = .uploading(progress: 0)
        errorMessage = nil

        if case .connected = connectionState {} else { await connect() }
        guard case .connected = connectionState, let t = transport else {
            diagLogger.error("startOTA() — SMP connection failed")
            errorMessage = "Could not connect to device for OTA"
            currentOperation = .none
            return
        }

        let hash = Data(SHA256.hash(data: data))
        let image = ImageManager.Image(image: 0, hash: hash, data: data)
        var config = FirmwareUpgradeConfiguration()
        config.upgradeMode = .uploadOnly

        let dfuManager = FirmwareUpgradeManager(transport: t, delegate: self)
        self.firmwareUpgradeManager = dfuManager
        diagLogger.info("startOTA() — upload started")

        do {
            try await withCheckedThrowingContinuation { continuation in
                self.upgradeContinuation = continuation
                dfuManager.start(images: [image], using: config)
            }
            diagLogger.info("startOTA() — upload complete")
        } catch {
            diagLogger.error("startOTA() failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        disconnect()
        currentOperation = .reconnecting
        try? await Task.sleep(for: .milliseconds(3000))
        try? await meshService.connectToProxy()
        diagLogger.info("startOTA() done — proxy reconnected")
        currentOperation = .none
    }

    // MARK: - Private: Scan

    nonisolated(unsafe) private static let smpServiceUUID = CBUUID(string: "8D53DC1D-1DB7-4CD3-868B-8A527460AA84")

    private func scanForDevice() async throws -> UUID {
        diagLogger.info("Scanning for '\(self.nodeName, privacy: .public)'")
        return try await withCheckedThrowingContinuation { continuation in
            self.scanContinuation = continuation
            self.smpCentralManager = CBCentralManager(delegate: self, queue: .main)
            Task {
                try? await Task.sleep(for: .seconds(15))
                await MainActor.run {
                    guard let cont = self.scanContinuation else { return }
                    diagLogger.warning("scanForDevice() — 15s timeout, no match for '\(self.nodeName, privacy: .public)'")
                    self.scanContinuation = nil
                    self.smpCentralManager?.stopScan()
                    self.smpCentralManager = nil
                    cont.resume(throwing: DiagnosticsError.deviceNotFound)
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceDiagnosticsViewModel: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        // Scan without a service UUID filter — the SMP service UUID is present in the GATT
        // table but not in the advertisement packet, so filtering by it yields no results.
        // Name matching in didDiscover selects the right device.
        central.scanForPeripherals(withServices: nil,
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        let name = peripheral.name
        let uuid = peripheral.identifier
        Task { @MainActor in
            guard scanContinuation != nil else { return }
            guard let rawName = name else { return }
            let trimmed = rawName.hasPrefix("DFU:") ? String(rawName.dropFirst(4)) : rawName
            guard trimmed == nodeName else { return }
            diagLogger.info("Found '\(rawName, privacy: .public)' \(uuid, privacy: .public)")
            let cont = scanContinuation
            scanContinuation = nil
            smpCentralManager?.stopScan()
            smpCentralManager = nil
            cont?.resume(returning: uuid)
        }
    }
}

// MARK: - FirmwareUpgradeDelegate

extension DeviceDiagnosticsViewModel: FirmwareUpgradeDelegate {

    nonisolated func upgradeDidStart(controller: any FirmwareUpgradeController) {}

    nonisolated func upgradeStateDidChange(from previousState: FirmwareUpgradeState,
                                           to newState: FirmwareUpgradeState) {
        diagLogger.info("OTA state: \(String(describing: newState), privacy: .public)")
    }

    nonisolated func uploadProgressDidChange(bytesSent: Int, imageSize: Int, timestamp: Date) {
        let progress = Double(bytesSent) / Double(imageSize)
        if Int(progress * 4) > Int((progress - 1.0 / Double(imageSize)) * 4) {
            diagLogger.info("OTA \(Int(progress * 100))% (\(bytesSent)/\(imageSize) bytes)")
        }
        Task { @MainActor in currentOperation = .uploading(progress: progress) }
    }

    nonisolated func upgradeDidComplete() {
        diagLogger.info("OTA complete")
        Task { @MainActor in
            upgradeContinuation?.resume()
            upgradeContinuation = nil
        }
    }

    nonisolated func upgradeDidFail(inState state: FirmwareUpgradeState, with error: Error) {
        diagLogger.error("FirmwareUpgrade failed in state \(String(describing: state), privacy: .public): \(error.localizedDescription, privacy: .public)")
        Task { @MainActor in
            upgradeContinuation?.resume(throwing: error)
            upgradeContinuation = nil
        }
    }

    nonisolated func upgradeDidCancel(state: FirmwareUpgradeState) {
        diagLogger.info("OTA cancelled")
        Task { @MainActor in
            upgradeContinuation?.resume(throwing: DiagnosticsError.cancelled)
            upgradeContinuation = nil
        }
    }
}
