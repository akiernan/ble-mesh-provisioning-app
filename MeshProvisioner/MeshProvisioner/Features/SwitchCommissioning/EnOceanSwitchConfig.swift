import Foundation

/// Credentials read from a PTM216B switch over NFC.
/// These are passed to the Silvair EnOcean Switch Mesh Proxy Server model
/// on each lighting node via ENOCEAN_PROXY_CONFIGURATION_SET.
struct EnOceanSwitchConfig: Equatable {
    /// 6-byte BLE static address: E2:15 prefix + 4 bytes from NFC page 0x0C.
    /// Bit 7 of byte index 2 (first byte after the E2:15 prefix) is set when
    /// the switch has encryption enabled, indicating a static random address.
    let bdAddress: Data

    /// 16-byte AES-128 security key from NFC pages 0x14–0x17.
    let securityKey: Data

    /// Human-readable BLE address string, e.g. "E2:15:AB:CD:EF:01".
    var addressString: String {
        bdAddress.map { String(format: "%02X", $0) }.joined(separator: ":")
    }
}
