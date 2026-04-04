import Foundation

/// Parses the ANSI/MH10.8.2-2013 commissioning string from a PTM216B QR/DataMatrix code.
///
/// QR string format (PTM216B User Manual §7.2):
///   30S<12hex>+Z<32hex>+30P<10char>+2P<4char>+31Z<8char>+S<14char>
///
/// Example:
///   30SE21501500100+Z0123456789ABCDEF0123456789ABCDEF+30PS3221-A216+2PDA03+31Z0000E215+S01234567890123
///
/// Only `30S` (Static Source Address, 12 hex chars) and `Z` (Security Key, 32 hex chars) are needed.
enum EnOceanQRParser {

    static func parse(_ string: String) throws -> EnOceanSwitchConfig {
        var addressHex: String?
        var keyHex: String?

        for field in string.components(separatedBy: "+") {
            if addressHex == nil, field.hasPrefix("30S") {
                let value = String(field.dropFirst(3))
                guard value.count == 12 else { throw EnOceanQRError.invalidFormat }
                addressHex = value
            } else if keyHex == nil, field.hasPrefix("Z") {
                let value = String(field.dropFirst(1))
                guard value.count == 32 else { throw EnOceanQRError.invalidFormat }
                keyHex = value
            }
        }

        guard let addressHex, let keyHex else {
            throw EnOceanQRError.missingFields
        }
        guard let addressData = Data(hexString: addressHex),
              let keyData = Data(hexString: keyHex) else {
            throw EnOceanQRError.invalidHex
        }

        return EnOceanSwitchConfig(bdAddress: addressData, securityKey: keyData)
    }
}

// MARK: - EnOceanQRError

enum EnOceanQRError: LocalizedError {
    case missingFields
    case invalidFormat
    case invalidHex

    var errorDescription: String? {
        switch self {
        case .missingFields: return "QR code is missing required switch credentials."
        case .invalidFormat: return "QR code has an unexpected format."
        case .invalidHex:    return "QR code contains invalid hex data."
        }
    }
}

// MARK: - Data hex init

private extension Data {
    init?(hexString: String) {
        let hex = hexString.uppercased()
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
