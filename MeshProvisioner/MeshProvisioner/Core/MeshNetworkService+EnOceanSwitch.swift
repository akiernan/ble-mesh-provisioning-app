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

// Silvair EnOcean Switch Mesh Proxy Server vendor model identifiers (used across multiple files)
let kSilvairCompanyId:     UInt16 = 0x0136
let kSilvairModelId:       UInt16 = 0x0001
/// Combined 32-bit vendor model ID as stored by NordicMesh (companyId << 16 | modelId)
let kSilvairVendorModelId: UInt32 = (UInt32(kSilvairCompanyId) << 16) | UInt32(kSilvairModelId)

private let kSilvairVendorOpCode: UInt32 = 0xF43601
private let kSubOpGet:    UInt8 = 0x00
private let kSubOpSet:    UInt8 = 0x01
private let kSubOpStatus: UInt8 = 0x03

// MARK: - Vendor Message Types

/// ENOCEAN_PROXY_CONFIGURATION_STATUS — SubOpCode 0x03.
/// Arrives as the acknowledged response to a SET or GET, and also as an
/// unsolicited notification. Registered in LightControlClientDelegate so
/// NordicMesh decodes it as a typed message instead of UnknownMessage.
struct EnOceanProxyConfigStatus: StaticVendorResponse {
    static let opCode: UInt32 = kSilvairVendorOpCode
    var parameters: Data?
    init?(parameters: Data) { self.parameters = parameters }
}

/// ENOCEAN_PROXY_CONFIGURATION_SET — SubOpCode 0x01.
/// Reliable (acknowledged) message; the node responds with
/// EnOceanProxyConfigStatus (same opCode, SubOpCode 0x03).
struct EnOceanProxyConfigSet: StaticAcknowledgedVendorMessage {
    static let opCode: UInt32 = kSilvairVendorOpCode
    static let responseType: StaticMeshResponse.Type = EnOceanProxyConfigStatus.self
    var parameters: Data?

    init(config: EnOceanSwitchConfig) {
        var data = Data([kSubOpSet])
        data += config.securityKey          // 16 bytes, MSB first (AES key, big-endian)
        data += config.bdAddress.reversed() // 6 bytes, LSB first (BT wire format)
        parameters = data
    }

    init?(parameters: Data) { return nil }  // not used for receiving
}

struct EnOceanProxyConfigGet: StaticUnacknowledgedVendorMessage {
    static let opCode: UInt32 = kSilvairVendorOpCode
    var parameters: Data? = Data([kSubOpGet])
    init?(parameters: Data) { return nil }  // not used for receiving
}

// MARK: - MeshNetworkService Extension

extension MeshNetworkService {

    /// Sends ENOCEAN_PROXY_CONFIGURATION_SET to the currently-connected GATT proxy node.
    ///
    /// Only one node needs the EnOcean proxy config — it scans for PTM216B BLE
    /// advertisements and translates them into mesh messages. We use the node we're
    /// currently proxied through because that's the one physically present during
    /// commissioning, and therefore the one closest to the switch being installed.
    ///
    /// SET is a reliable (acknowledged) message — NordicMesh retransmits until
    /// the node responds with a STATUS, or the library timeout fires.
    func configureEnOceanSwitch(_ config: EnOceanSwitchConfig) async throws {
        guard let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No application key configured")
        }
        try await connectToProxy()

        // Prefer the currently-connected proxy node if it has the Silvair vendor model;
        // otherwise fall back to the first node that does.
        let proxyNode = manager.proxyFilter.proxy
        guard let targetNode = silvairNodes.first(where: { $0 === proxyNode }) ?? silvairNodes.first else {
            throw AppError.messageSendFailed("No node with Silvair vendor model found")
        }
        // The SET message must be addressed to the element that hosts the
        // Silvair vendor model, not the node's primary element (element 0).
        // In BLE Mesh, unicast messages are routed to the element with the
        // matching address; element 0 does not have the vendor model.
        guard let silvairElement = targetNode.elements.first(where: {
            $0.models.contains { $0.companyIdentifier == kSilvairCompanyId && $0.modelIdentifier == kSilvairModelId }
        }) else {
            throw AppError.messageSendFailed("Proxy node 0x\(String(targetNode.primaryUnicastAddress, radix: 16)) has no Silvair element")
        }
        let elementAddress = silvairElement.unicastAddress
        let dest = MeshAddress(elementAddress)
        logger.info("📡 Sending ENOCEAN_PROXY_CONFIGURATION_SET for \(config.addressString) to element 0x\(String(elementAddress, radix: 16)) on node 0x\(String(targetNode.primaryUnicastAddress, radix: 16))")

        let message = EnOceanProxyConfigSet(config: config)
        try? await manager.send(message, to: dest, using: appKey)
        // STATUS response arrives via the delegate (handleEnOceanStatus) — the library
        // delivers vendor responses through MeshNetworkDelegate, not as a return value.
        logger.info("📡 EnOcean switch config sent — awaiting STATUS via delegate")
    }

    /// All provisioned nodes that host the Silvair EnOcean Switch Mesh Proxy Server
    /// (Company 0x0136, Model 0x0001). Falls back to all provisioned nodes when
    /// composition data hasn't been fetched yet (no node has the vendor model recorded).
    var silvairNodes: [Node] {
        let nodes = provisionedNodes.filter { node in
            node.elements.contains { element in
                element.models.contains {
                    $0.companyIdentifier == kSilvairCompanyId && $0.modelIdentifier == kSilvairModelId
                }
            }
        }
        return nodes.isEmpty ? provisionedNodes : nodes
    }
}

extension MeshNetworkService {
    /// Called from MeshNetworkDelegate when an EnOceanProxyConfigStatus arrives.
    /// Handles both solicited responses (from a SET/GET) and unsolicited STATUS pushes.
    func handleEnOceanStatus(_ message: EnOceanProxyConfigStatus, from source: Address) {
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
