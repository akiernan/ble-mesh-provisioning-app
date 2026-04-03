import Foundation
import CoreBluetooth

// MARK: - Discovered Device

struct DiscoveredDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let peripheral: CBPeripheral
    let advertisementData: Data

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: DiscoveredDevice, rhs: DiscoveredDevice) -> Bool { lhs.id == rhs.id }

    var signalStrength: SignalStrength {
        if rssi > -50 { return .excellent }
        if rssi > -60 { return .good }
        if rssi > -70 { return .fair }
        return .weak
    }

    enum SignalStrength {
        case excellent, good, fair, weak
        var label: String {
            switch self {
            case .excellent: "Excellent"
            case .good: "Good"
            case .fair: "Fair"
            case .weak: "Weak"
            }
        }
    }
}

// MARK: - Provisioning State

enum ProvisioningDeviceState: Equatable {
    case pending
    case inProgress(progress: Double)
    case completed
    case failed(String)

    static func == (lhs: ProvisioningDeviceState, rhs: ProvisioningDeviceState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.completed, .completed): true
        case (.inProgress(let a), .inProgress(let b)): a == b
        case (.failed(let a), .failed(let b)): a == b
        default: false
        }
    }
}

// MARK: - Key Binding

enum KeyBindingStep: Int, CaseIterable {
    case connectProxy
    case generateKey
    case distributeKeys
    case configureModels

    var title: String {
        switch self {
        case .connectProxy: "Connect to Proxy"
        case .generateKey: "Generate Application Key"
        case .distributeKeys: "Distribute Keys"
        case .configureModels: "Configure Models"
        }
    }

    var description: String {
        switch self {
        case .connectProxy: "Establishing GATT proxy connection"
        case .generateKey: "Creating secure 128-bit AES encryption keys"
        case .distributeKeys: "Binding keys to devices"
        case .configureModels: "Setting up Light CTL model"
        }
    }
}

enum KeyBindingStepState: Equatable {
    case pending, inProgress, completed, failed(String)

    static func == (lhs: KeyBindingStepState, rhs: KeyBindingStepState) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending), (.inProgress, .inProgress), (.completed, .completed): true
        case (.failed(let a), .failed(let b)): a == b
        default: false
        }
    }
}

// MARK: - Mesh Group

struct MeshGroupConfig: Identifiable, Hashable {
    let id: String
    let name: String
    let groupAddress: UInt16
    let nodeUnicastAddresses: [UInt16]
    var isOn: Bool
    var lightness: Double  // 0.0 – 1.0
    var temperature: UInt16  // Kelvin (2000–8000)

    static let temperatureMin: UInt16 = 800
    static let temperatureMax: UInt16 = 20000

    var temperatureRangeMin: UInt16 = MeshGroupConfig.temperatureMin
    var temperatureRangeMax: UInt16 = MeshGroupConfig.temperatureMax

    /// Lightness range as 0.0–1.0. Min defaults to 1% so the slider never sends 0 (off).
    var lightnessRangeMin: Double = 0.01
    var lightnessRangeMax: Double = 1.0

    var lightnessUInt16: UInt16 { UInt16(lightness * 65535) }

    func temperatureLabel() -> String {
        switch temperature {
        case 0..<2500: "Warm"
        case 2500..<4000: "Neutral Warm"
        case 4000..<5500: "Neutral"
        case 5500..<7000: "Cool"
        default: "Daylight"
        }
    }
}

// MARK: - Node Key Binding State

struct NodeKeyBindingState: Identifiable {
    let id: UUID
    let name: String
    var state: KeyBindingStepState
}


// MARK: - App Error

enum AppError: LocalizedError {
    case bluetoothUnavailable
    case provisioningFailed(String)
    case keyBindingFailed(String)
    case groupConfigFailed(String)
    case messageSendFailed(String)
    case networkNotReady

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Bluetooth is not available on this device."
        case .provisioningFailed(let msg): "Provisioning failed: \(msg)"
        case .keyBindingFailed(let msg): "Key binding failed: \(msg)"
        case .groupConfigFailed(let msg): "Group configuration failed: \(msg)"
        case .messageSendFailed(let msg): "Failed to send message: \(msg)"
        case .networkNotReady: "Mesh network is not ready."
        }
    }
}
