@preconcurrency import NordicMesh
import Foundation

// MARK: - Silvair EnOcean Proxy Configuration Messages
//
// Vendor model: Company ID 0x0136 (Silvair), Model ID 0x0001
// All messages share opCode 0xF43601; the SubOpCode is parameters[0].
//
// ENOCEAN_PROXY_CONFIGURATION_SET   SubOpCode 0x01
//   payload: SubOpCode(1) + SecurityKey(16) + SourceAddress(6) = 23 bytes
//
// ENOCEAN_PROXY_CONFIGURATION_GET   SubOpCode 0x00
//   payload: SubOpCode(1) = 1 byte
//
// ENOCEAN_PROXY_CONFIGURATION_STATUS SubOpCode 0x03
//   payload: SubOpCode(1) + Status(1) + optional SourceAddress(6) = 2-8 bytes

private let kSilvaireVendorOpCode: UInt32 = 0xF43601
private let kSubOpGet:    UInt8 = 0x00
private let kSubOpSet:    UInt8 = 0x01
private let kSubOpStatus: UInt8 = 0x03

// MARK: - Vendor Message Types

struct EnOceanProxyConfigSet: StaticUnacknowledgedVendorMessage {
    static let opCode: UInt32 = kSilvaireVendorOpCode
    var parameters: Data?

    init(config: EnOceanSwitchConfig) {
        var data = Data([kSubOpSet])
        data += config.securityKey   // 16 bytes
        data += config.bdAddress     // 6 bytes
        parameters = data
    }

    init?(parameters: Data) { return nil }  // not used for receiving
}

struct EnOceanProxyConfigGet: StaticUnacknowledgedVendorMessage {
    static let opCode: UInt32 = kSilvaireVendorOpCode
    var parameters: Data? = Data([kSubOpGet])
    init?(parameters: Data) { return nil }  // not used for receiving
}

// MARK: - MeshNetworkService Extension

extension MeshNetworkService {

    /// Sends ENOCEAN_PROXY_CONFIGURATION_SET to the single node that hosts
    /// the Silvair EnOcean Switch Mesh Proxy Server vendor model.
    ///
    /// Only one node needs this config — it receives PTM216B BLE advertisements
    /// and translates them into mesh messages for the rest of the network.
    /// We prefer the node with the Silvair vendor model (Company 0x0136, Model 0x0001);
    /// if composition data doesn't reveal it, we fall back to the first provisioned node.
    ///
    /// The message is sent three times at 50 ms intervals to improve delivery
    /// reliability (mirrors the switch's own burst pattern).
    func configureEnOceanSwitch(_ config: EnOceanSwitchConfig) async throws {
        guard let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No application key configured")
        }
        guard let targetNode = enOceanProxyNode else {
            throw AppError.messageSendFailed("No provisioned node to configure")
        }
        try await connectToProxy()

        let dest = MeshAddress(targetNode.primaryUnicastAddress)
        let message = EnOceanProxyConfigSet(config: config)

        logger.info("📡 Sending ENOCEAN_PROXY_CONFIGURATION_SET for \(config.addressString) to node 0x\(String(targetNode.primaryUnicastAddress, radix: 16))")
        for i in 0..<3 {
            try? await manager.send(message, to: dest, using: appKey)
            if i < 2 {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        logger.info("📡 EnOcean switch config sent")
    }

    /// The node that runs the Silvair EnOcean Switch Mesh Proxy Server.
    /// Prefers the node whose composition data includes the Silvair vendor model
    /// (Company ID 0x0136, Model ID 0x0001); falls back to the first provisioned node.
    var enOceanProxyNode: Node? {
        let silvairCompanyId: UInt16 = 0x0136
        let silvairModelId:   UInt16 = 0x0001
        return provisionedNodes.first {
            $0.elements.contains { element in
                element.models.contains { model in
                    model.companyIdentifier == silvairCompanyId &&
                    model.modelIdentifier   == silvairModelId
                }
            }
        } ?? provisionedNodes.first
    }
}

// MARK: - LightServerDelegate opcode registration

// The STATUS response (SubOpCode 0x03) arrives with opCode 0xF43601.
// We register it in LightControlClientDelegate so the library decodes it
// as a typed message rather than UnknownMessage — see MeshNetworkService.swift.
//
// The decoded message arrives in meshNetworkManager(_:didReceiveMessage:…) where
// MeshNetworkService.handleEnOceanStatus(_:) is called if the opcode matches.

extension MeshNetworkService {
    /// Called from MeshNetworkDelegate when a vendor message with the Silvair opcode arrives.
    func handleEnOceanStatus(_ message: UnknownMessage, from source: Address) {
        guard let params = message.parameters, params.count >= 2,
              params[0] == kSubOpStatus else { return }
        let status = params[1]
        switch status {
        case 0x00:
            let addr = params.count >= 8
                ? params[2..<8].map { String(format: "%02X", $0) }.joined(separator: ":")
                : "(no address)"
            logger.info("✅ EnOcean proxy config success from 0x\(String(source, radix: 16)): \(addr)")
        case 0x01:
            logger.warning("⚠️ EnOcean proxy config not set (0x\(String(source, radix: 16)))")
        case 0x02:
            logger.error("❌ EnOcean proxy config unspecified error (0x\(String(source, radix: 16)))")
        default:
            logger.warning("⚠️ EnOcean proxy config unknown status 0x\(String(status, radix: 16))")
        }
    }
}
