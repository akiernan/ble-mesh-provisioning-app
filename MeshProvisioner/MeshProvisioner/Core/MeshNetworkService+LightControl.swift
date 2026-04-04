@preconcurrency import NordicMesh

// MARK: - Light CTL Control

extension MeshNetworkService {

    func setOnOff(_ on: Bool) async throws {
        guard let group = currentGroup,
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No group or app key configured")
        }
        try await connectToProxy()
        let dest = MeshAddress(group.groupAddress)
        let message = GenericOnOffSetUnacknowledged(on)
        try? await manager.send(message, to: dest, using: appKey)
        currentGroup?.isOn = on
    }

    func setLightCTL(lightness: Double, temperature: UInt16) async throws {
        guard let group = currentGroup,
              let appKey = manager.meshNetwork?.applicationKeys.first else {
            throw AppError.messageSendFailed("No group or app key configured")
        }
        try await connectToProxy()
        let dest = MeshAddress(group.groupAddress)
        let lMin = currentGroup?.lightnessRangeMin ?? 0.01
        let lMax = currentGroup?.lightnessRangeMax ?? 1.0
        let clamped = lightness <= 0 ? 0.0 : max(lMin, min(lMax, lightness))
        let lightnessValue = UInt16(clamped * 65535)
        let rangeMin = currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
        let rangeMax = currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
        let clampedTemp = max(rangeMin, min(rangeMax, temperature))
        let transition = TransitionTime(steps: 2, stepResolution: .hundredsOfMilliseconds) // 200ms
        let message = LightCTLSetUnacknowledged(lightness: lightnessValue,
                                                temperature: clampedTemp,
                                                deltaUV: 0,
                                                transitionTime: transition,
                                                delay: 0)
        try? await manager.send(message, to: dest, using: appKey)
    }
}

// MARK: - State Query

extension MeshNetworkService {

    /// Queries a provisioned node for its current on/off and CTL state,
    /// updating `currentGroup` to reflect the real device values.
    func fetchCurrentState() async {
        guard let node = provisionedNodes.first else { return }
        guard let appKey = manager.meshNetwork?.applicationKeys.first else { return }
        isFetchingState = true
        defer { isFetchingState = false }

        // Note: the proxy filter is configured as an empty reject list (= accept all) via
        // manager.proxyFilter.initialState, so we must NOT call proxyFilter.add() here.
        // Adding an address to a reject-list filter would BLOCK that address.

        // Bind the app key to local client models (persisted after first run)
        let localElement = manager.localElements.first
        let clientModelIds: [UInt16] = [.genericOnOffClientModelId, .lightCTLClientModelId]
        for modelId in clientModelIds {
            if let model = localElement?.model(withSigModelId: modelId),
               !model.boundApplicationKeys.contains(where: { $0.index == appKey.index }) {
                if let bind = ConfigModelAppBind(applicationKey: appKey, to: model) {
                    _ = try? await manager.sendToLocalNode(bind)
                }
            }
        }
        _ = manager.save()

        // Query GenericOnOff state from the first provisioned node
        if let onOffModel = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .genericOnOffServerModelId) }).first {
            do {
                let response = try await manager.send(GenericOnOffGet(), to: onOffModel)
                if let status = response as? GenericOnOffStatus {
                    logger.info("🔄 OnOff state: \(status.isOn ? "ON" : "OFF")")
                    currentGroup?.isOn = status.isOn
                }
            } catch {
                logger.warning("🔄 Failed to query OnOff state: \(error)")
            }
        }

        // Query LightCTL state
        if let ctlModel = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .lightCTLServerModelId) }).first {
            do {
                let response = try await manager.send(LightCTLGet(), to: ctlModel)
                if let status = response as? LightCTLStatus {
                    let lightness = Double(status.lightness) / 65535.0
                    logger.info("🔄 CTL state: lightness=\(Int(lightness * 100))%, temp=\(status.temperature)K")
                    currentGroup?.lightness = lightness
                    currentGroup?.temperature = status.temperature
                }
            } catch {
                logger.warning("🔄 Failed to query CTL state: \(error)")
            }
        }

        // Query Light Lightness range
        if let lightnessServer = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .lightLightnessServerModelId) }).first {
            do {
                let response = try await manager.send(LightLightnessRangeGet(), to: lightnessServer)
                if let status = response as? LightLightnessRangeStatus, status.min > 0 {
                    let rMin = Double(status.min) / 65535.0
                    let rMax = Double(status.max) / 65535.0
                    logger.info("🔄 Lightness range: \(Int(rMin * 100))%–\(Int(rMax * 100))%")
                    currentGroup?.lightnessRangeMin = rMin
                    currentGroup?.lightnessRangeMax = rMax
                    if let l = currentGroup?.lightness {
                        currentGroup?.lightness = max(rMin, min(rMax, l))
                    }
                }
            } catch {
                logger.warning("🔄 Failed to query lightness range: \(error)")
            }
        }

        // Query LightCTL temperature range (sent to CTL Server, same as LightCTLGet)
        if let ctlServerForRange = node.elements.lazy
            .compactMap({ $0.model(withSigModelId: .lightCTLServerModelId) }).first {
            do {
                let response = try await manager.send(LightCTLTemperatureRangeGet(), to: ctlServerForRange)
                if let status = response as? LightCTLTemperatureRangeStatus {
                    logger.info("🔄 CTL temperature range: \(status.min)K–\(status.max)K")
                    currentGroup?.temperatureRangeMin = status.min
                    currentGroup?.temperatureRangeMax = status.max
                    if let temp = currentGroup?.temperature {
                        currentGroup?.temperature = max(status.min, min(status.max, temp))
                    }
                }
            } catch {
                logger.warning("🔄 Failed to query CTL temperature range: \(error)")
            }
        }
    }
}

// MARK: - MeshNetworkDelegate

extension MeshNetworkService: MeshNetworkDelegate {

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         didReceiveMessage message: MeshMessage,
                                         sentFrom source: Address,
                                         to destination: MeshAddress) {
        // Resolve any config continuation waiting for this opCode from this node.
        // Must happen before the loopback guard — local node config responses have
        // source == provisioner address and would otherwise be silently dropped.
        let configKey = ConfigContinuationKey(sourceAddress: source, responseOpCode: message.opCode)
        Task { @MainActor in
            if let cont = pendingConfigContinuations.removeValue(forKey: configKey) {
                cont.resume()
            }
        }

        // Ignore loopback — messages we sent to a group that echo back via the proxy filter.
        // Config responses are already handled above so this only suppresses state updates.
        guard source != manager.meshNetwork?.localProvisioner?.primaryUnicastAddress else { return }
        logger.info("📩 RECEIVED \(type(of: message)) opCode=0x\(String(message.opCode, radix: 16)) from 0x\(String(source, radix: 16)) to 0x\(String(destination.address, radix: 16))")
        if message is ConfigCompositionDataStatus {
            logger.info("📩 Got composition data response!")
        }
        if let status = message as? ConfigStatusMessage {
            logger.info("📩 Config status: \(status.isSuccess ? "success" : "failed"): \(status.message)")
        }
        // Update group state from incoming commands (switch) and status responses.
        Task { @MainActor in
            switch message {
            case let cmd as GenericOnOffSetUnacknowledged:
                logger.info("🔄 OnOff command received: \(cmd.isOn ? "ON" : "OFF")")
                self.currentGroup?.isOn = cmd.isOn

            case let status as GenericOnOffStatus:
                logger.info("🔄 OnOff state: \(status.isOn ? "ON" : "OFF")")
                self.currentGroup?.isOn = status.isOn

            case let cmd as GenericLevelSet:
                if destination.address == 0xC002 {
                    // Second Silvair controller → colour temperature
                    let tMin = self.currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
                    let tMax = self.currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
                    let normalized = (Double(cmd.level) + 32768.0) / 65535.0
                    let temp = tMin + UInt16(normalized * Double(tMax - tMin))
                    logger.info("🌡️ CTL level command (second controller): \(cmd.level) → \(temp)K")
                    self.currentGroup?.temperature = temp
                } else {
                    let lightnessRaw = UInt16(Int32(cmd.level) + 32768)
                    let lightness = Double(lightnessRaw) / 65535.0
                    logger.info("🔄 Level command received: \(cmd.level) → lightness=\(Int(lightness * 100))%")
                    self.currentGroup?.lightness = lightness
                    if lightnessRaw == 0 { self.currentGroup?.isOn = false }
                    else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }
                }

            case let cmd as GenericLevelSetUnacknowledged:
                if destination.address == 0xC002 {
                    let tMin = self.currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
                    let tMax = self.currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
                    let normalized = (Double(cmd.level) + 32768.0) / 65535.0
                    let temp = tMin + UInt16(normalized * Double(tMax - tMin))
                    logger.info("🌡️ CTL level command (second controller): \(cmd.level) → \(temp)K")
                    self.currentGroup?.temperature = temp
                } else {
                    let lightnessRaw = UInt16(Int32(cmd.level) + 32768)
                    let lightness = Double(lightnessRaw) / 65535.0
                    logger.info("🔄 Level command received: \(cmd.level) → lightness=\(Int(lightness * 100))%")
                    self.currentGroup?.lightness = lightness
                    if lightnessRaw == 0 { self.currentGroup?.isOn = false }
                    else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }
                }

            case let cmd as GenericDeltaSetUnacknowledged:
                if destination.address == 0xC002 {
                    // Delta from second Silvair controller → colour temperature change
                    let tMin = self.currentGroup?.temperatureRangeMin ?? MeshGroupConfig.temperatureMin
                    let tMax = self.currentGroup?.temperatureRangeMax ?? MeshGroupConfig.temperatureMax
                    let currentTemp = self.currentGroup?.temperature ?? UInt16((Double(tMin) + Double(tMax)) / 2.0)
                    let tempFraction = tMax > tMin
                        ? max(0.0, min(1.0, Double(Int(currentTemp) - Int(tMin)) / Double(Int(tMax) - Int(tMin))))
                        : 0.5
                    let currentLevel = Int32(tempFraction * 65535.0) - 32768
                    let newLevel = max(-32768, min(32767, currentLevel + cmd.delta))
                    let newFraction = (Double(newLevel) + 32768.0) / 65535.0
                    let temp = tMin + UInt16(newFraction * Double(tMax - tMin))
                    logger.info("🌡️ CTL delta command (second controller): Δ\(cmd.delta) → \(temp)K")
                    self.currentGroup?.temperature = temp
                } else {
                    let currentLevel = Int32((self.currentGroup?.lightness ?? 0.5) * 65535) - 32768
                    let newLevel = max(-32768, min(32767, currentLevel + cmd.delta))
                    let lightnessRaw = UInt16(newLevel + 32768)
                    let lightness = Double(lightnessRaw) / 65535.0
                    logger.info("🔄 Delta command received: Δ\(cmd.delta) → level=\(newLevel), lightness=\(Int(lightness * 100))%")
                    self.currentGroup?.lightness = lightness
                    if lightnessRaw == 0 { self.currentGroup?.isOn = false }
                    else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }
                }

            case let status as GenericLevelStatus:
                let lightnessRaw = UInt16(Int32(status.level) + 32768)
                let lightness = Double(lightnessRaw) / 65535.0
                logger.info("🔄 Level status received: \(status.level) → lightness=\(Int(lightness * 100))%")
                self.currentGroup?.lightness = lightness

            case let cmd as LightLightnessSetUnacknowledged:
                let lightness = Double(cmd.lightness) / 65535.0
                logger.info("🔄 Lightness command received: lightness=\(Int(lightness * 100))%")
                self.currentGroup?.lightness = lightness
                if cmd.lightness == 0 { self.currentGroup?.isOn = false }
                else if self.currentGroup?.isOn == false { self.currentGroup?.isOn = true }

            case let status as LightLightnessStatus:
                let lightness = Double(status.lightness) / 65535.0
                logger.info("🔄 Lightness status received: lightness=\(Int(lightness * 100))%")
                self.currentGroup?.lightness = lightness

            case let cmd as LightCTLSetUnacknowledged:
                let lightness = Double(cmd.lightness) / 65535.0
                logger.info("🔄 CTL command received: lightness=\(Int(lightness * 100))%, temp=\(cmd.temperature)K")
                self.currentGroup?.lightness = lightness
                self.currentGroup?.temperature = cmd.temperature

            case let status as LightCTLStatus:
                let lightness = Double(status.lightness) / 65535.0
                logger.info("🔄 CTL state: lightness=\(Int(lightness * 100))%, temp=\(status.temperature)K")
                self.currentGroup?.lightness = lightness
                self.currentGroup?.temperature = status.temperature

            case let status as LightCTLTemperatureRangeStatus:
                logger.info("🔄 CTL temperature range: \(status.min)K–\(status.max)K")
                self.currentGroup?.temperatureRangeMin = status.min
                self.currentGroup?.temperatureRangeMax = status.max
                if let temp = self.currentGroup?.temperature {
                    self.currentGroup?.temperature = max(status.min, min(status.max, temp))
                }

            case let status as LightLightnessRangeStatus where status.min > 0:
                let rMin = Double(status.min) / 65535.0
                let rMax = Double(status.max) / 65535.0
                logger.info("🔄 Lightness range: \(Int(rMin * 100))%–\(Int(rMax * 100))%")
                self.currentGroup?.lightnessRangeMin = rMin
                self.currentGroup?.lightnessRangeMax = rMax
                if let l = self.currentGroup?.lightness {
                    self.currentGroup?.lightness = max(rMin, min(rMax, l))
                }

            default:
                if message.opCode == 0xF43601, let vendor = message as? UnknownMessage {
                    self.handleEnOceanStatus(vendor, from: source)
                } else {
                    logger.warning("📩 Unhandled message type: \(type(of: message)) opCode=0x\(String(message.opCode, radix: 16))")
                }
            }
        }
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         didSendMessage message: MeshMessage,
                                         from localElement: Element,
                                         to destination: MeshAddress) {
        logger.info("📤 SENT \(type(of: message)) to 0x\(String(destination.address, radix: 16))")
    }

    nonisolated func meshNetworkManager(_ manager: MeshNetworkManager,
                                         failedToSendMessage message: MeshMessage,
                                         from localElement: Element,
                                         to destination: MeshAddress,
                                         error: Error) {
        logger.error("❌ FAILED to send \(type(of: message)) to 0x\(String(destination.address, radix: 16)): \(error)")
    }
}

// MARK: - LoggerDelegate

extension MeshNetworkService: LoggerDelegate {
    nonisolated func log(message: String, ofCategory category: LogCategory, withLevel level: LogLevel) {
        switch level {
        case .error:   logger.error("[\(category.rawValue)] \(message)")
        case .warning: logger.warning("[\(category.rawValue)] \(message)")
        case .info:    logger.info("[\(category.rawValue)] \(message)")
        default:       logger.debug("[\(category.rawValue)] \(message)")
        }
    }
}
