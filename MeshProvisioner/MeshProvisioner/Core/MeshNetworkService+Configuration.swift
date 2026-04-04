import Foundation
@preconcurrency import NordicMesh

// MARK: - Message Sending

extension MeshNetworkService {

    /// Sends an acknowledged config message and waits until the expected response
    /// opCode arrives from that node (or 8 seconds elapse).
    ///
    /// This works around the library bug where `manager.send()` never resolves when
    /// the device's response arrives as `UnknownMessage`: we match on the raw opCode
    /// value directly in our delegate callback, which fires regardless of type.
    func sendConfig(_ message: AcknowledgedConfigMessage, to node: Node) async {
        let key = ConfigContinuationKey(
            sourceAddress: node.primaryUnicastAddress,
            responseOpCode: message.responseOpCode
        )
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            pendingConfigContinuations[key] = cont
            Task { [manager] in _ = try? await manager.send(message, to: node) }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(8))
                guard let self else { return }
                if let cont = pendingConfigContinuations.removeValue(forKey: key) {
                    logger.warning("🔧 Config send to 0x\(String(node.primaryUnicastAddress, radix: 16)) timed out")
                    cont.resume()
                }
            }
        }
    }

    /// Runs an async operation with a timeout. If the timeout fires first, execution
    /// continues immediately — the operation is left running in the background but
    /// does not block progress. This is critical because `manager.send()` can hang
    /// forever when proxy notifications aren't working and the response is never received.
    func withTimeout(
        _ timeout: Duration = .seconds(8),
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        let gate = OnceGate()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Task {
                try? await operation()
                if gate.tryPass() { continuation.resume() }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if gate.tryPass() {
                    logger.warning("Config message timed out — continuing")
                    continuation.resume()
                }
            }
        }
    }
}

// MARK: - Key Binding

extension MeshNetworkService {

    func performKeyBinding(nodes: [Node]) async throws {
        guard let network = manager.meshNetwork else { throw AppError.networkNotReady }

        // Step 0: Connect to GATT proxy
        keyBindingStepStates[.connectProxy] = .inProgress
        // Allow the device to transition from PB-GATT provisioning to proxy mode
        try await Task.sleep(for: .seconds(2))
        try await connectToProxy()
        keyBindingStepStates[.connectProxy] = .completed

        // Step 1: Generate / retrieve application key
        keyBindingStepStates[.generateKey] = .inProgress
        guard let appKey = network.applicationKeys.first else {
            throw AppError.keyBindingFailed("No application key found")
        }
        try await Task.sleep(for: .milliseconds(300))
        keyBindingStepStates[.generateKey] = .completed

        // Step 2: Distribute keys – fetch composition data then send ConfigAppKeyAdd
        keyBindingStepStates[.distributeKeys] = .inProgress
        nodeKeyBindingStates = nodes.map {
            NodeKeyBindingState(id: $0.uuid, name: $0.name ?? "Mesh Node", state: .pending)
        }
        for node in nodes {
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .inProgress
            }
            logger.info("🔧 Processing node: \(node.name ?? "unknown"), unicast: 0x\(String(node.primaryUnicastAddress, radix: 16)), elements: \(node.elements.count)")
            logger.info("🔧 Proxy connected: \(self.isConnectedToProxy), transmitter: \(self.manager.transmitter != nil), bearer: \(self.proxyBearer != nil)")

            // Fetch composition data so we know the node's elements and models.
            let hasModels = node.elements.contains { !$0.models.isEmpty }
            if !hasModels {
                logger.info("🔧 Sending ConfigCompositionDataGet to node 0x\(String(node.primaryUnicastAddress, radix: 16)) (\(node.elements.count) elements, no models)...")
                let compositionGet = ConfigCompositionDataGet(page: 0)
                logger.info("🔧 manager.send(CompositionDataGet) — awaiting response...")
                await sendConfig(compositionGet, to: node)
                try? await Task.sleep(for: .milliseconds(500))
                logger.info("🔧 After CompositionDataGet — node elements: \(node.elements.count)")
                for (i, element) in node.elements.enumerated() {
                    let modelNames = element.models.map { "0x\(String($0.modelId, radix: 16))" }.joined(separator: ", ")
                    logger.info("🔧   Element[\(i)] addr=0x\(String(element.unicastAddress, radix: 16)) models=[\(modelNames)]")
                }
            } else {
                logger.info("🔧 Node already has composition data (\(node.elements.count) elements)")
            }

            logger.info("🔧 Sending ConfigAppKeyAdd to node 0x\(String(node.primaryUnicastAddress, radix: 16))...")
            let request = ConfigAppKeyAdd(applicationKey: appKey)
            await sendConfig(request, to: node)
            try? await Task.sleep(for: .milliseconds(200))
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .completed
            }
        }
        keyBindingStepStates[.distributeKeys] = .completed

        // Step 3: Configure model binding on each node
        keyBindingStepStates[.configureModels] = .inProgress
        nodeKeyBindingStates = nodes.map {
            NodeKeyBindingState(id: $0.uuid, name: $0.name ?? "Mesh Node", state: .pending)
        }
        for node in nodes {
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .inProgress
            }
            let hasModels = node.elements.contains { !$0.models.isEmpty }
            if !hasModels {
                logger.warning("🔧 Node \(node.name ?? "unknown") has no models — skipping model bind")
                if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                    nodeKeyBindingStates[idx].state = .completed
                }
                continue
            }
            for (i, element) in node.elements.enumerated() {
                let modelNames = element.models.map { "0x\(String($0.modelId, radix: 16))" }.joined(separator: ", ")
                logger.info("🔧 Element[\(i)] models: [\(modelNames)]")
                for model in element.models {
                    // Bind app key to every non-config SIG model
                    let modelId = model.modelId
                    guard modelId != 0x0000 && modelId != 0x0001 else { continue }
                    if let bindMsg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        logger.info("🔧 Binding app key to model 0x\(String(modelId, radix: 16)) on element \(i)")
                        await sendConfig(bindMsg, to: node)
                        try? await Task.sleep(for: .milliseconds(100))
                    }
                }
            }
            if let idx = nodeKeyBindingStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeKeyBindingStates[idx].state = .completed
            }
        }
        keyBindingStepStates[.configureModels] = .completed

        _ = manager.save()
    }
}

// MARK: - Group Configuration

extension MeshNetworkService {

    func configureGroup(name: String, nodes: [Node]) async throws -> MeshGroupConfig {
        guard let network = manager.meshNetwork else { throw AppError.networkNotReady }

        // Ensure proxy connection is active
        if !isConnectedToProxy {
            try await connectToProxy()
        }

        // Main lighting group: OnOff / Level / Lightness / CTL commands
        let mainGroupAddress: Address = 0xC001
        let mainGroup: Group
        if let existing = network.group(withAddress: MeshAddress(mainGroupAddress)) {
            mainGroup = existing
        } else {
            do {
                mainGroup = try Group(name: name, address: MeshAddress(mainGroupAddress))
                try network.add(group: mainGroup)
            } catch {
                throw AppError.groupConfigFailed(error.localizedDescription)
            }
        }

        // CTL temperature group: Generic Level commands from the Silvair switch's second controller
        let ctlTempGroupAddress: Address = 0xC002
        let ctlTempGroup: Group
        if let existing = network.group(withAddress: MeshAddress(ctlTempGroupAddress)) {
            ctlTempGroup = existing
        } else {
            do {
                ctlTempGroup = try Group(name: "\(name) CTL Temperature", address: MeshAddress(ctlTempGroupAddress))
                try network.add(group: ctlTempGroup)
            } catch {
                throw AppError.groupConfigFailed(error.localizedDescription)
            }
        }

        guard let appKey = network.applicationKeys.first else {
            throw AppError.groupConfigFailed("No application key available")
        }

        // Models that bind transitively to Light CTL Server / Light Lightness Server.
        // These live in the primary lighting element and should all subscribe to the group.
        let ctlLightnessBindingIds: Set<UInt16> = [
            .genericOnOffServerModelId,                 // 0x1000
            .genericLevelServerModelId,                 // 0x1002
            .genericDefaultTransitionTimeServerModelId, // 0x1004
            .genericPowerOnOffServerModelId,            // 0x1006
            .genericPowerOnOffSetupServerModelId,       // 0x1007
            .lightLightnessServerModelId,               // 0x1300
            .lightLightnessSetupServerModelId,          // 0x1301
            .lightCTLServerModelId,                     // 0x1303
            .lightCTLSetupServerModelId,                // 0x1304
        ]

        // Models that bind transitively to Light CTL Temperature Server.
        // These live in the secondary CTL temperature element.
        let ctlTempBindingIds: Set<UInt16> = [
            .genericLevelServerModelId,                 // 0x1002
            .genericDefaultTransitionTimeServerModelId, // 0x1004
            .lightCTLTemperatureServerModelId,          // 0x1306
        ]

        // Silvair vendor model (CID 0x0136, ModelID 0x0001) identifies a switch element.
        let silvairVendorModelId: UInt32 = (UInt32(0x0136) << 16) | UInt32(0x0001)
        // OnOff + Level clients in the Silvair element publish to the main lighting group.
        let switchClientIds: Set<UInt16> = [
            .genericOnOffClientModelId, // 0x1001
            .genericLevelClientModelId, // 0x1003
        ]
        let mainSwitchPublication = Publish(
            to: MeshAddress(mainGroupAddress),
            using: appKey,
            usingFriendshipMaterial: false,
            ttl: 5,
            period: .disabled,
            retransmit: .disabled
        )
        // The Level Client in the element immediately after the Silvair element publishes
        // to the CTL temperature group so the second controller controls colour temperature.
        let ctlTempPublication = Publish(
            to: MeshAddress(ctlTempGroupAddress),
            using: appKey,
            usingFriendshipMaterial: false,
            ttl: 5,
            period: .disabled,
            retransmit: .disabled
        )

        // Helper: which models should subscribe, and to which group.
        // Primary lighting element → main group; CTL temp element → CTL temp group.
        func subscribeTarget(for element: Element) -> (ids: Set<UInt16>, group: Group)? {
            let ids = Set(element.models.map { $0.modelIdentifier })
            if ids.contains(.lightCTLServerModelId) || ids.contains(.lightLightnessServerModelId) {
                return (ctlLightnessBindingIds, mainGroup)
            } else if ids.contains(.lightCTLTemperatureServerModelId) {
                return (ctlTempBindingIds, ctlTempGroup)
            }
            return nil
        }

        // Models for local provisioner element 0 → bound and subscribed to main group (0xC001).
        let localServerIds: Set<UInt16> = [
            .genericOnOffServerModelId,
            .genericLevelServerModelId,
            .lightLightnessServerModelId,
            .lightLightnessSetupServerModelId,
            .lightCTLServerModelId,
            .lightCTLSetupServerModelId,
        ]
        // Models for local provisioner element 1 → bound and subscribed to CTL temp group (0xC002).
        let localCTLTempServerIds: Set<UInt16> = [
            .genericLevelServerModelId,
            .lightCTLTemperatureServerModelId,
        ]

        // Count total BLE operations upfront for progress reporting.
        var totalOps = 0
        for node in nodes {
            let elements = Array(node.elements)
            for (elementIndex, element) in elements.enumerated() {
                let target = subscribeTarget(for: element)
                let hasSilvair = element.models.contains(where: { $0.modelId == silvairVendorModelId })
                for model in element.models {
                    if let t = target, t.ids.contains(model.modelIdentifier),
                       ConfigModelSubscriptionAdd(group: t.group, to: model) != nil { totalOps += 1 }
                    if hasSilvair && switchClientIds.contains(model.modelIdentifier),
                       ConfigModelPublicationSet(mainSwitchPublication, to: model) != nil { totalOps += 1 }
                }
                // Level Client in element+1 after the Silvair element → CTL temp group
                if hasSilvair && elementIndex + 1 < elements.count {
                    let nextEl = elements[elementIndex + 1]
                    for model in nextEl.models where model.modelIdentifier == .genericLevelClientModelId {
                        if ConfigModelPublicationSet(ctlTempPublication, to: model) != nil { totalOps += 1 }
                    }
                }
            }
        }
        // Include local provisioner ops: element 0 → main group, element 1 → CTL temp group.
        let localNode = network.localProvisioner?.node
        let localName = localNode?.name ?? "This Device"
        if let localNode {
            let localElements = Array(localNode.elements)
            if !localElements.isEmpty {
                for model in localElements[0].models where localServerIds.contains(model.modelIdentifier) {
                    totalOps += 2 // ConfigModelAppBind + ConfigModelSubscriptionAdd
                }
            }
            if localElements.count > 1 {
                for model in localElements[1].models where localCTLTempServerIds.contains(model.modelIdentifier) {
                    totalOps += 2 // ConfigModelAppBind + ConfigModelSubscriptionAdd
                }
            }
        }
        totalOps = max(1, totalOps)
        var completedOps = 0

        groupConfigProgress = 0
        groupConfigStatus = "Starting…"
        var initialStates = nodes.enumerated().map { idx, node in
            NodeKeyBindingState(id: node.uuid, name: node.name ?? "Device \(idx + 1)", state: .pending)
        }
        if let localNode {
            initialStates.append(NodeKeyBindingState(id: localNode.uuid, name: localName, state: .pending))
        }
        nodeGroupConfigStates = initialStates

        for (nodeIndex, node) in nodes.enumerated() {
            let nodeName = node.name ?? "Device \(nodeIndex + 1)"
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeGroupConfigStates[idx].state = .inProgress
            }
            let elements = Array(node.elements)
            for (elementIndex, element) in elements.enumerated() {
                let target = subscribeTarget(for: element)
                let hasSilvair = element.models.contains(where: { $0.modelId == silvairVendorModelId })
                if hasSilvair { silvairSwitchNode = node }
                for model in element.models {
                    // Subscribe lighting models to the appropriate group
                    if let t = target, t.ids.contains(model.modelIdentifier),
                       let msg = ConfigModelSubscriptionAdd(group: t.group, to: model) {
                        groupConfigStatus = "Subscribing \(nodeName) to group…"
                        logger.info("🔧 Subscribing model 0x\(String(model.modelId, radix: 16)) to \(t.group.name)")
                        await sendConfig(msg, to: node)
                        try? await Task.sleep(for: .milliseconds(200))
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                    // Silvair main controller: OnOff + Level publish to main group
                    if hasSilvair && switchClientIds.contains(model.modelIdentifier),
                       let msg = ConfigModelPublicationSet(mainSwitchPublication, to: model) {
                        groupConfigStatus = "Configuring switch publish on \(nodeName)…"
                        logger.info("🔧 Configuring switch client 0x\(String(model.modelId, radix: 16)) → 0xC001")
                        await sendConfig(msg, to: node)
                        try? await Task.sleep(for: .milliseconds(200))
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                }
                // Silvair element+1: Level Client publishes to CTL temp group (OnOff ignored)
                if hasSilvair && elementIndex + 1 < elements.count {
                    let nextEl = elements[elementIndex + 1]
                    for model in nextEl.models where model.modelIdentifier == .genericLevelClientModelId {
                        if let msg = ConfigModelPublicationSet(ctlTempPublication, to: model) {
                            groupConfigStatus = "Configuring CTL temp switch on \(nodeName)…"
                            logger.info("🔧 Configuring CTL switch client 0x\(String(model.modelId, radix: 16)) → 0xC002")
                            await sendConfig(msg, to: node)
                            try? await Task.sleep(for: .milliseconds(200))
                            completedOps += 1
                            groupConfigProgress = Double(completedOps) / Double(totalOps)
                        }
                    }
                }
            }
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == node.uuid }) {
                nodeGroupConfigStates[idx].state = .completed
            }
        }

        // Bind app key and subscribe local provisioner models.
        // Element 0 (lighting servers) → main group; element 1 (CTL temp level) → CTL temp group.
        if let localNode {
            let localId = localNode.uuid
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == localId }) {
                nodeGroupConfigStates[idx].state = .inProgress
            }
            groupConfigStatus = "Configuring \(localName)…"
            let localElements = Array(localNode.elements)
            if !localElements.isEmpty {
                for model in localElements[0].models where localServerIds.contains(model.modelIdentifier) {
                    if let msg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                    if let msg = ConfigModelSubscriptionAdd(group: mainGroup, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                }
            }
            if localElements.count > 1 {
                for model in localElements[1].models where localCTLTempServerIds.contains(model.modelIdentifier) {
                    if let msg = ConfigModelAppBind(applicationKey: appKey, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                    if let msg = ConfigModelSubscriptionAdd(group: ctlTempGroup, to: model) {
                        await sendConfig(msg, to: localNode)
                        completedOps += 1
                        groupConfigProgress = Double(completedOps) / Double(totalOps)
                    }
                }
            }
            if let idx = nodeGroupConfigStates.firstIndex(where: { $0.id == localId }) {
                nodeGroupConfigStates[idx].state = .completed
            }
        }

        groupConfigProgress = 1.0
        groupConfigStatus = "Done"

        _ = manager.save()

        let config = MeshGroupConfig(
            id: UUID().uuidString,
            name: name,
            groupAddress: mainGroupAddress,
            nodeUnicastAddresses: nodes.map { $0.primaryUnicastAddress },
            isOn: false,
            lightness: 0.5,
            temperature: 4000
        )
        currentGroup = config
        return config
    }
}

// MARK: - OnceGate

/// Thread-safe gate that allows only the first caller through.
/// Used to ensure a continuation is resumed exactly once in a race between
/// an operation completing and a timeout firing.
private final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var passed = false
    func tryPass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !passed else { return false }
        passed = true
        return true
    }
}
