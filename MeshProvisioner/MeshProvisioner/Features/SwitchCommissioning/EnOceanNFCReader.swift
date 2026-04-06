@preconcurrency import CoreNFC
import Foundation
import os.log

private let nfcLogger = Logger(subsystem: "uk.a-squared-projects.MeshProvisioner", category: "EnOceanNFC")

/// Wraps NFCMiFareTag (not Sendable) for safe crossing of actor boundaries.
/// Safe because CoreNFC serialises all tag access on the queue supplied to NFCTagReaderSession.
private struct SendableMiFareTag: @unchecked Sendable {
    let tag: any NFCMiFareTag
}

// MARK: - EnOceanNFCReader

/// Reads PTM216B switch credentials over NFC using CoreNFC.
///
/// The PTM216B uses an NXP NTAG I2C Plus 1k chip (NFC Forum Type 2 / ISO 14443-3A).
/// Page layout used here:
///   0x0C – 4 bytes: BLE address suffix (prefixed with E2:15 to form a 6-byte BD address)
///   0x0E – 4 bytes: config flags (byte 2 bit 5 = encryption; sets MSB of address suffix byte 0)
///   0x14 – 16 bytes (pages 0x14–0x17): 16-byte AES-128 security key
///
/// Authentication: PWD_AUTH (0x1B) with default password [0x00, 0x00, 0xE2, 0x15].
/// The user may supply a custom password if the switch has been re-configured.
@MainActor
final class EnOceanNFCReader: NSObject {

    private static let defaultPassword: [UInt8] = [0x00, 0x00, 0xE2, 0x15]

    private var session: NFCTagReaderSession?
    private var continuation: CheckedContinuation<EnOceanSwitchConfig, Error>?
    private let password: [UInt8]

    init(password: [UInt8] = EnOceanNFCReader.defaultPassword) {
        self.password = password
    }

    /// Present the system NFC scan sheet and return credentials when the tag is read.
    func read() async throws -> EnOceanSwitchConfig {
        guard NFCTagReaderSession.readingAvailable else {
            throw EnOceanNFCError.notAvailable
        }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            guard let session = NFCTagReaderSession(pollingOption: .iso14443, delegate: self, queue: .main) else {
                continuation.resume(throwing: EnOceanNFCError.notAvailable)
                return
            }
            session.alertMessage = "Hold your EnOcean switch near the top of your iPhone."
            session.begin()
            self.session = session
        }
    }

    // MARK: - Private

    private func process(tag: SendableMiFareTag) async {
        let tag = tag.tag
        do {
            // Authenticate
            let authResponse = try await tag.sendMiFareCommand(commandPacket: Data(
                [0x1B] + password
            ))
            guard authResponse.count >= 2 else {
                throw EnOceanNFCError.authFailed
            }
            nfcLogger.info("NFC auth OK, PACK=\(authResponse.map { String(format: "%02X", $0) }.joined())")

            // Read page 0x0E (config flags) — READ returns 4 pages = 16 bytes
            let flagsData = try await tag.sendMiFareCommand(commandPacket: Data([0x30, 0x0E]))
            guard flagsData.count >= 4 else { throw EnOceanNFCError.unexpectedResponse }
            let encryptionEnabled = (flagsData[2] & 0x20) != 0

            // Read page 0x0C (BLE address suffix) — 16 bytes, first 4 are page 0x0C
            let addrData = try await tag.sendMiFareCommand(commandPacket: Data([0x30, 0x0C]))
            guard addrData.count >= 4 else { throw EnOceanNFCError.unexpectedResponse }
            var addrSuffix = [UInt8](addrData[0..<4])
            if encryptionEnabled {
                addrSuffix[0] |= 0x80  // static random address flag
            }
            let bdAddress = Data([0xE2, 0x15] + addrSuffix)

            // Read pages 0x14–0x17 (security key) — READ 0x14 returns 16 bytes covering all 4 pages
            let keyData = try await tag.sendMiFareCommand(commandPacket: Data([0x30, 0x14]))
            guard keyData.count >= 16 else { throw EnOceanNFCError.unexpectedResponse }
            let securityKey = keyData.prefix(16)

            let config = EnOceanSwitchConfig(bdAddress: bdAddress, securityKey: Data(securityKey))
            nfcLogger.info("NFC read OK: address=\(config.addressString)")

            session?.alertMessage = "Switch credentials read successfully."
            session?.invalidate()
            continuation?.resume(returning: config)
            continuation = nil

        } catch let error as EnOceanNFCError {
            session?.invalidate(errorMessage: error.localizedDescription)
            continuation?.resume(throwing: error)
            continuation = nil
        } catch {
            nfcLogger.error("NFC read error: \(error)")
            session?.invalidate(errorMessage: "Failed to read switch. Please try again.")
            continuation?.resume(throwing: EnOceanNFCError.readFailed(error))
            continuation = nil
        }
    }
}

// MARK: - NFCTagReaderSessionDelegate

extension EnOceanNFCReader: NFCTagReaderSessionDelegate {

    nonisolated func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {
        nfcLogger.info("NFC session active")
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        let nfcError = error as? NFCReaderError
        // User-cancelled (code 200) is not a real error
        guard nfcError?.code != .readerSessionInvalidationErrorUserCanceled else { return }
        nfcLogger.warning("NFC session invalidated: \(error)")
        Task { @MainActor in
            self.continuation?.resume(throwing: EnOceanNFCError.sessionInvalidated(error))
            self.continuation = nil
        }
    }

    nonisolated func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard let tag = tags.first else { return }
        // Check tag type before connecting — NFCTag type is known from advertisement.
        guard case .miFare(let mifareTag) = tag else {
            session.invalidate(errorMessage: "Unsupported tag type. Please use an EnOcean PTM216B switch.")
            Task { @MainActor in
                self.continuation?.resume(throwing: EnOceanNFCError.unsupportedTag)
                self.continuation = nil
            }
            return
        }
        // Wrap session to safely cross the @Sendable closure boundary.
        // Safe because CoreNFC serialises all session callbacks on its own queue.
        struct SendableSession: @unchecked Sendable { let value: NFCTagReaderSession }
        let sendableSession = SendableSession(value: session)
        let sendableTag = SendableMiFareTag(tag: mifareTag)
        session.connect(to: tag) { [weak self] error in
            if let error {
                sendableSession.value.invalidate(errorMessage: "Connection failed.")
                Task { @MainActor in
                    self?.continuation?.resume(throwing: EnOceanNFCError.connectionFailed(error))
                    self?.continuation = nil
                }
                return
            }
            Task { @MainActor in
                await self?.process(tag: sendableTag)
            }
        }
    }
}

// MARK: - EnOceanNFCError

enum EnOceanNFCError: LocalizedError {
    case notAvailable
    case authFailed
    case unsupportedTag
    case unexpectedResponse
    case connectionFailed(Error)
    case sessionInvalidated(Error)
    case readFailed(Error)

    var errorDescription: String? {
        switch self {
        case .notAvailable:         return "NFC is not available on this device."
        case .authFailed:           return "Switch authentication failed. Check the NFC password."
        case .unsupportedTag:       return "This tag is not an EnOcean PTM216B switch."
        case .unexpectedResponse:   return "Unexpected response from switch. Please try again."
        case .connectionFailed:     return "Failed to connect to switch tag."
        case .sessionInvalidated(let e): return e.localizedDescription
        case .readFailed(let e):    return e.localizedDescription
        }
    }
}
