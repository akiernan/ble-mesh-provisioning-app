# Architecture Document — BLE Mesh Provisioning App

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Platform | iOS 17+ / macOS 14+ |
| Language | Swift 6.0 (strict concurrency) |
| UI | SwiftUI |
| Architecture | MVVM with `@Observable` |
| BLE Mesh library | NordicMesh (IOS-nRF-Mesh-Library) via SPM |
| Concurrency | Swift async/await, `@MainActor`, `nonisolated` callbacks |
| Persistence | `MeshNetwork.json` in Documents, managed by `MeshNetworkManager` |

---

## Project Structure

```
MeshProvisioner/
├── App/
│   ├── MeshProvisionerApp.swift     # @main, NavigationStack root, environment injection
│   └── AppRouter.swift              # @Observable NavigationPath wrapper
├── Core/
│   ├── MeshNetworkService.swift     # All BLE/mesh logic (single service class)
│   ├── Models.swift                 # Value types: DiscoveredDevice, MeshGroupConfig, enums
│   └── GradientProgressStyle.swift  # Custom ProgressViewStyle with gradient fill and fixed height
└── Features/
    ├── Discovery/
    │   ├── DeviceDiscoveryView.swift
    │   └── DeviceDiscoveryViewModel.swift
    ├── Provisioning/
    │   ├── ProvisioningView.swift
    │   └── ProvisioningViewModel.swift
    ├── KeyBinding/
    │   ├── KeyBindingView.swift
    │   └── KeyBindingViewModel.swift
    ├── GroupConfig/
    │   ├── GroupConfigView.swift
    │   └── GroupConfigViewModel.swift
    └── DeviceControl/
        ├── DeviceControlView.swift
        └── DeviceControlViewModel.swift
```

---

## Navigation

`AppRouter` wraps `NavigationPath`. The root view is always `DeviceDiscoveryView`. Routes:

```swift
enum AppRoute: Hashable {
    case provisioning
    case keyBinding
    case groupConfig
    case deviceControl
}
```

On app launch, `MeshProvisionerApp.onAppear` checks `meshService.hasProvisionedNetwork`. If `true` (a group at 0xC001 exists and nodes are provisioned), it immediately pushes `.deviceControl`, skipping the setup flow.

All post-provisioning screens hide the back button (`navigationBarBackButtonHidden(true)`) to enforce the forward-only flow. The only way back to discovery is via factory reset.

---

## Dependency Injection

`MeshNetworkService` and `AppRouter` are created as `@State` in `MeshProvisionerApp` and injected via `.environment(meshService)` / `.environment(router)`. ViewModels receive them via constructor injection from their parent View's `@Environment`.

---

## MeshNetworkService

The central service class. `@Observable @MainActor`. Owns all BLE and mesh state.

### Init sequence

1. Creates `MeshNetworkManager`.
2. Creates `CBCentralManager` (for scanning) on `.main`.
3. Calls `setupMeshNetwork()` — loads or creates the mesh network and app key.
4. Calls `setupLocalElements()` — installs local models and configures proxy filter.

### Local Node Element Structure

The iPhone presents itself as a mesh node with two elements:

```
Element 0 — Primary Element
├── GenericOnOffClient       (0x1001) — sends GenericOnOffSet to group
├── LightCTLClient           (0x1305) — sends LightCTLSet to group; receives status
├── GenericOnOffServer       (0x1000) ─┐
├── GenericLevelServer       (0x1002)  │
├── GenericDefaultTTServer   (0x1004)  │ Subscribed to 0xC001 during group config.
├── GenericPowerOnOffServer  (0x1006)  │ Enables receipt of lightness/on-off commands
├── GenericPowerOnOffSetup   (0x1007)  │ from external switches/dimmers.
├── LightLightnessServer     (0x1300)  │
├── LightLightnessSetup      (0x1301)  │
├── LightCTLServer           (0x1303)  │
└── LightCTLSetupServer      (0x1304) ─┘

Element 1 — CTL Temperature Element
├── GenericLevelServer       (0x1002) ─┐ Subscribed to 0xC002 during group config.
└── GenericDefaultTTServer   (0x1004) ─┘ Enables receipt of colour temperature level
                                          commands from the Silvair switch's second controller.
```

**Why server models on the iPhone?** The NordicMesh library only decodes incoming mesh messages for models registered in `localElements`. Without server models subscribed to the group addresses, group-addressed commands from external switches (e.g. `GenericOnOffSetUnacknowledged`) would arrive as `UnknownMessage` and could not be pattern-matched in `didReceiveMessage`.

**Why a second element for CTL temperature?** The CTL temperature element on lighting nodes uses a separate `GenericLevelServer` bound to the `LightCTLTemperatureServer` — addressing that Generic Level channel controls colour temperature, not brightness. Mirroring this structure locally means the app can subscribe the second element to the separate 0xC002 group, ensuring Generic Level messages on 0xC001 (brightness) and 0xC002 (temperature) are delivered to different models and can be distinguished by destination address in `didReceiveMessage`.

### Proxy Filter Strategy

```swift
manager.proxyFilter.initialState = .rejectList(addresses: [])
```

An empty reject list means the GATT proxy forwards **all** mesh traffic to the iPhone. This is critical for two reasons:

1. `ProxyFilter.add(address:)` is `internal` in the NordicMesh library — it cannot be called from app code to manage an accept list after connection.
2. The accept-list alternative would require knowing all relevant group addresses at the moment of proxy connection. The empty reject list avoids this entirely.

**CRITICAL**: Never call `proxyFilter.add(address:)` anywhere in app code. When the filter is in reject-list mode, calling `add()` would add the address to the **reject** list (blocking), not the accept list (allowing).

The filter is set via `initialState` before connection. When the proxy connects, `newProxyDidConnect()` in the library sends `SetFilterType(.rejectList)` followed by the empty list. The proxy then forwards everything. The app receives `FilterStatus` and `proxyFilter.proxy` becomes non-nil.

---

## Provisioning Pipeline

### Overview

Each device is provisioned independently over its own `PBGattBearer` (one CBCentralManager-driven GATT connection per device). The flow is sequential in `ProvisioningViewModel.runProvisioning()`.

### Sequence per device

```
1. provisionDevice(device)
   └── provisionWithPeripheral(device:peripheral:)
       ├── Create UnprovisionedDevice(uuid: device.id, ...)
       ├── Create PBGattBearer(targetWithIdentifier: peripheral.identifier)
       ├── manager.provision(unprovisionedDevice:over:bearer)  → ProvisioningManager
       ├── Create ProvisioningBearerBridge (strong reference — bearer.delegate is weak)
       ├── bearer.open()
       └── await CheckedThrowingContinuation<Node>
           ├── bearerDidOpen → pm.identify(andAttractFor: 0)
           ├── provisioningState(.requestingCapabilities) → inProgress(0.2)
           ├── provisioningState(.capabilitiesReceived)   → inProgress(0.4)
           │   └── pm.provision(algorithm: .BTM_ECDH_P256_CMAC_AES128_AES_CCM,
           │                    publicKey: .noOobPublicKey,
           │                    authenticationMethod: .noOob)
           ├── provisioningState(.provisioning)           → inProgress(0.7)
           └── provisioningState(.complete)               → inProgress(1.0) → .completed
               └── finishProvisioning(.success(node))
                   └── continuation.resume(returning: node)
2. provisionedNodes.append(node)
3. 400ms delay before next device
```

### OOB information

Extracted from the last 2 bytes (bytes 16–17) of the `MeshProvisioningService` advertisement service data. Used as `OobInformation` in `UnprovisionedDevice`. With `authenticationMethod: .noOob`, no user input is required.

### After provisioning

After the last device is provisioned, a 1-second delay allows the devices to reboot from PB-GATT mode into proxy mode before `performKeyBinding` attempts to connect.

---

## Key Binding Pipeline

`MeshNetworkService.performKeyBinding(nodes:)` — four sequential steps:

### Step 0: Connect to Proxy (`connectProxy`)

- 2-second delay to allow devices to transition from PB-GATT to proxy advertising mode.
- `connectToProxy()` scans for `MeshProxyService.uuid`, connects, and awaits bearer open.
- After bearer open, polls `manager.proxyFilter.proxy` every 100ms for up to 5 seconds until `FilterStatus` is received and the proxy is ready.

### Step 1: Generate Application Key (`generateKey`)

- Retrieves the existing app key (created during `setupMeshNetwork`) or creates a new 128-bit key bound to the network key.
- 300ms visual pause.

### Step 2: Distribute Keys (`distributeKeys`)

For each node:
1. If the node has no models (composition data not yet fetched), sends `ConfigCompositionDataGet(page: 0)` → `sendConfig()`.
2. Sends `ConfigAppKeyAdd(applicationKey: appKey)` → `sendConfig()`.
3. Per-device sub-row in the UI transitions: `.pending → .inProgress → .completed`.

### Step 3: Configure Model App Bindings (`configureModels`)

For each node:
- Iterates every element, every model.
- Skips config server (0x0000) and config client (0x0001).
- Sends `ConfigModelAppBind(applicationKey:to:model)` for every other SIG model.
- 100ms delay between binds to avoid flooding the BLE bearer.
- Per-device sub-row transitions: `.pending → .inProgress → .completed`.

---

## Group Configuration Pipeline

`MeshNetworkService.configureGroup(name:nodes:)`:

### Group addresses

Two groups are created (if they don't already exist):

| Address | Name | Purpose |
|---------|------|---------|
| `0xC001` | `<room name>` | Main lighting group — OnOff, brightness, full CTL |
| `0xC002` | `<room name> CTL Temperature` | CTL temperature channel — second Silvair controller |

### Subscription model sets

**CTL Lightness element** (element containing `LightCTLServer` or `LightLightnessServer`) → subscribed to **0xC001**:
```
0x1000 GenericOnOffServer
0x1002 GenericLevelServer
0x1004 GenericDefaultTransitionTimeServer
0x1006 GenericPowerOnOffServer
0x1007 GenericPowerOnOffSetupServer
0x1300 LightLightnessServer
0x1301 LightLightnessSetupServer
0x1303 LightCTLServer
0x1304 LightCTLSetupServer
```

**CTL Temperature element** (element containing `LightCTLTemperatureServer`) → subscribed to **0xC002**:
```
0x1002 GenericLevelServer
0x1004 GenericDefaultTransitionTimeServer
0x1306 LightCTLTemperatureServer
```

Isolating the CTL temp element to 0xC002 prevents Generic Level messages on the main group from inadvertently driving colour temperature through the CTL temperature binding.

Each matching model receives a `ConfigModelSubscriptionAdd(group:to:model)`.

### Switch/dimmer publication (Silvair detection)

Elements are iterated with enumerated index to support the element+1 look-ahead.

**Silvair element** (contains vendor model `CID 0x0136, ModelID 0x0001`):
- `GenericOnOffClient` (0x1001) and `GenericLevelClient` (0x1003) → publish to **0xC001** (TTL=5, period=disabled, retransmit=disabled).

**Element immediately after the Silvair element** (index+1):
- `GenericLevelClient` (0x1003) → publish to **0xC002** (TTL=5, period=disabled, retransmit=disabled).
- `GenericOnOffClient` in this element is left unconfigured.

This allows the physical switch's second level controller to independently drive colour temperature while the first controller drives brightness.

### Local node configuration

After all remote nodes are done, the iPhone's local node is configured per-element:

**Element 0** (Primary — lightness/on-off servers):
- `ConfigModelAppBind` + `ConfigModelSubscriptionAdd` to **0xC001** for each model in `localServerIds`.

**Element 1** (CTL Temperature — GenericLevel + GenericDefaultTT servers):
- `ConfigModelAppBind` + `ConfigModelSubscriptionAdd` to **0xC002** for each model in `localCTLTempServerIds`.

### Progress reporting

Total operations are counted upfront across all nodes and both elements of the local node, including the Silvair element+1 publication ops. Each `sendConfig` call increments `completedOps` and sets `groupConfigProgress = completedOps / totalOps`. Per-device state rows track overall progress in the UI.

---

## `sendConfig` — Config Message Helper

Many config messages in the NordicMesh library return responses as `UnknownMessage` rather than their typed response class (because `ConfigurationClientHandler` only decodes messages for models it has registered). To work around this, `sendConfig` uses a custom keying mechanism:

```swift
struct ConfigContinuationKey: Hashable {
    let sourceAddress: UInt16   // node's primary unicast address
    let responseOpCode: UInt32  // expected response opCode
}
```

In `meshNetworkManager(_:didReceiveMessage:sentFrom:to:)`, **before** the loopback guard, the incoming message's `opCode` is matched against `pendingConfigContinuations`. If a match is found, the continuation is resumed. This fires regardless of whether the message is typed or `UnknownMessage`.

A fallback 8-second timeout per send prevents the pipeline from hanging if a device never responds.

---

## Proxy Connection Lifecycle

```
connectToProxy()
  ├── Guard: mesh network exists
  ├── Guard: not already connected
  ├── Wait for CBManagerState == .poweredOn (up to 5s)
  ├── scanForPeripherals(withServices: [MeshProxyService.uuid])
  ├── centralManager(_:didDiscover:) → connectToProxyPeripheral(_:)
  │   ├── Create GattBearer(targetWithIdentifier:)
  │   ├── bearer.dataDelegate = manager
  │   ├── manager.transmitter = bearer
  │   └── bearer.open()
  ├── bearerDidOpen(_:) → isConnectedToProxy = true → resume continuation
  └── Poll proxyFilter.proxy != nil (up to 5s, 100ms interval)
      └── Returns only after FilterStatus received → proxy filter ready

Auto-reconnect:
  bearer(_:didClose:) with no pending continuation + hasProvisionedNetwork
  └── 1s delay → connectToProxy()
```

The 15-second total timeout on `connectToProxy()` covers the full scan-to-bearer-open time.

---

## Message Receive Dispatch

`MeshNetworkDelegate.meshNetworkManager(_:didReceiveMessage:sentFrom:to:)` — `nonisolated`, posts all state updates to `@MainActor` via `Task { @MainActor in }`.

### Config continuation resolution (first, before any guard)

Matches `(source, message.opCode)` against `pendingConfigContinuations`. Resolves before the loopback guard so that local node config responses (source == provisioner address) are not suppressed.

### Loopback suppression

```swift
guard source != manager.meshNetwork?.localProvisioner?.primaryUnicastAddress else { return }
```

Messages the app sent to 0xC001 loop back via the proxy (TTL-1, different bytes) and are discarded by lower transport as replays (same seqAuth). The few that do reach `didReceiveMessage` would otherwise apply to `currentGroup` twice. This guard prevents that for messages originating from the local node.

### State update switch

The destination address determines how Generic Level messages are interpreted:
- `destination.address == 0xC002` → colour temperature command
- anything else → brightness/lightness command

```swift
switch message {
case GenericOnOffSetUnacknowledged:  currentGroup.isOn = cmd.isOn
case GenericOnOffStatus:             currentGroup.isOn = status.isOn

case GenericLevelSet / Unacknowledged:
    if destination == 0xC002:
        // Second Silvair controller → colour temperature
        normalized = (Double(cmd.level) + 32768) / 65535     // 0.0–1.0
        temp = tMin + UInt16(normalized * Double(tMax - tMin))
        currentGroup.temperature = temp
    else:
        // Primary channel → brightness
        lightnessRaw = UInt16(Int32(cmd.level) + 32768)
        currentGroup.lightness = Double(lightnessRaw) / 65535
        // also updates isOn based on lightnessRaw == 0

case GenericDeltaSetUnacknowledged:
    if destination == 0xC002:
        // Delta from second controller → colour temperature change
        fraction = clamp((currentTemp - tMin) / (tMax - tMin), 0, 1)
        currentLevel = Int32(fraction * 65535) - 32768
        newLevel = clamp(currentLevel + cmd.delta, -32768, 32767)
        newFraction = (Double(newLevel) + 32768) / 65535
        currentGroup.temperature = tMin + UInt16(newFraction * Double(tMax - tMin))
    else:
        // Relative delta — applied to current lightness
        currentLevel = Int32(currentGroup.lightness * 65535) - 32768
        newLevel = clamp(currentLevel + cmd.delta, -32768, 32767)
        lightnessRaw = UInt16(newLevel + 32768)
        currentGroup.lightness = Double(lightnessRaw) / 65535

case GenericLevelStatus:             currentGroup.lightness = ...
case LightLightnessSetUnacknowledged: currentGroup.lightness = ...
case LightLightnessStatus:           currentGroup.lightness = ...
case LightCTLSetUnacknowledged:      currentGroup.{lightness,temperature} = ...
case LightCTLStatus:                 currentGroup.{lightness,temperature} = ...
case LightCTLTemperatureRangeStatus: currentGroup.{temperatureRangeMin,Max} = ...
case LightLightnessRangeStatus:      currentGroup.{lightnessRangeMin,Max} = ...
}
```

### Level ↔ Lightness conversion

BLE Mesh `GenericLevel` range is [-32768, 32767]. BLE Mesh `LightLightness` range is [0, 65535].

```
lightness_uint16 = UInt16(Int32(level) + 32768)
lightness_double = Double(lightness_uint16) / 65535.0

level = Int32(lightness_double * 65535) - 32768
```

### Level ↔ Temperature conversion

BLE Mesh `GenericLevel` range is [-32768, 32767]. Temperature range is `[tMin, tMax]` in Kelvin (from `LightCTLTemperatureRangeStatus`).

```
normalized = (Double(level) + 32768) / 65535.0   // 0.0–1.0
temperature = tMin + UInt16(normalized * Double(tMax - tMin))

// Inverse (for delta):
fraction = clamp((currentTemp - tMin) / (tMax - tMin), 0.0, 1.0)
level = Int32(fraction * 65535) - 32768
```

---

## Model Delegates

### `LightControlClientDelegate`

Assigned to local `GenericOnOffClient` and `LightCTLClient` models. Registers opcodes so the library decodes status responses as typed messages (enabling `manager.send()` continuations to resolve):

```
GenericOnOffStatus, LightCTLStatus, LightCTLTemperatureRangeStatus, LightLightnessRangeStatus,
ConfigCompositionDataStatus, ConfigAppKeyStatus, ConfigModelAppStatus,
ConfigModelSubscriptionStatus, ConfigModelPublicationStatus
```

`isSubscriptionSupported = false` — client models do not subscribe to groups.

### `LightServerDelegate`

Assigned to all local server models across both elements (element 0 and element 1). Registers opcodes so the library:
1. Decodes incoming set/status messages as typed objects (enabling the switch dispatch in `didReceiveMessage`).
2. Supports group subscriptions (`isSubscriptionSupported = true`).

Registered opcodes:
```
GenericOnOffSetUnacknowledged, GenericOnOffStatus,
GenericLevelSet, GenericLevelSetUnacknowledged, GenericDeltaSetUnacknowledged, GenericLevelStatus,
LightLightnessSetUnacknowledged, LightLightnessStatus,
LightCTLSetUnacknowledged, LightCTLStatus
```

`GenericLevelSet` (acknowledged) is handled by returning `GenericLevelStatus(level: cmd.level)` from `didReceiveAcknowledgedMessage` — required because some dimmers send the acknowledged variant and expect a response.

---

## State Query on Connect

`fetchCurrentState()` is called after `connectToProxy()` in `DeviceControlViewModel.connectIfNeeded()`. It queries the first provisioned node using unicast addressing (not group addressing):

1. `GenericOnOffGet` → `GenericOnOffStatus` → `currentGroup.isOn`
2. `LightCTLGet` → `LightCTLStatus` → `currentGroup.{lightness, temperature}`
3. `LightLightnessRangeGet` → `LightLightnessRangeStatus` → `currentGroup.{lightnessRangeMin, lightnessRangeMax}`
4. `LightCTLTemperatureRangeGet` → `LightCTLTemperatureRangeStatus` → `currentGroup.{temperatureRangeMin, temperatureRangeMax}`

Range values from the device clamp the UI sliders to what the hardware actually supports.

---

## Device Control Send Path

### `setOnOff(on:)`

Sends `GenericOnOffSetUnacknowledged` to `MeshAddress(0xC001)` using the app key. Updates `currentGroup.isOn` immediately after send (optimistic).

### `setLightCTL(lightness:temperature:)`

Sends `LightCTLSetUnacknowledged` to `MeshAddress(0xC001)`. Lightness is clamped to `[lightnessRangeMin, lightnessRangeMax]` (0 is a special case — sends 0 directly for off). Temperature is clamped to `[temperatureRangeMin, temperatureRangeMax]`. Transition time: 200ms.

### ACK-gated send loop (`DeviceControlViewModel`)

```
setLightness(x) or setTemperature(x)
  ├── Update currentGroup immediately (optimistic UI)
  ├── Store in pendingLightness/pendingTemperature (overwrites previous)
  └── triggerSendIfIdle()
      └── if !isSending:
          isSending = true
          Task { sendLoop() }
              └── while pending values exist:
                  consume pendingLightness + pendingTemperature
                  send LightCTLSetUnacknowledged
                  sleep 100ms (bearer drain time)
              isSending = false
```

Only the latest pending value is ever sent. Fast slider drags produce at most one in-flight send at a time with intermediate values discarded.

---

## Factory Reset

`factoryResetAllNodes()`:
1. Sends `ConfigNodeReset` to each node via `sendConfig()` (sequential, uses unicast addressing).
2. 800ms delay.
3. `resetMeshNetwork()`:
   - Disconnects and nils `proxyBearer`, `manager.transmitter`.
   - Stops BLE scan.
   - Deletes `MeshNetwork.json`.
   - Resets all `@Observable` state properties to initial values.
   - Calls `setupMeshNetwork()` + `setupLocalElements()` to create a fresh network.

---

## Concurrency Model

- `MeshNetworkService` is `@Observable @MainActor`. All state mutations happen on MainActor.
- NordicMesh delegate callbacks (`nonisolated`) bridge to MainActor via `Task { @MainActor in }`.
- `CBCentralManager` is created on `.main` queue. Its `nonisolated` delegate methods extract all non-`Sendable` values from `advertisementData` before crossing into the `Task` boundary.
- `CheckedContinuation` / `CheckedThrowingContinuation` bridge async code to callback-based APIs (provisioning, proxy connection, config messages).
- `OnceGate` (NSLock-based) ensures continuations used in race-between-operation-and-timeout are resumed exactly once.
- `ProvisioningBearerBridge` holds a strong reference to itself as a bearer delegate (since `bearer.delegate` is `weak`) via `activeBearerDelegates[deviceID]`.

---

## Key Constants

| Constant | Value | Purpose |
|----------|-------|---------|
| Main group address | `0xC001` | Lighting control — OnOff, brightness, full CTL |
| CTL temp group address | `0xC002` | Colour temperature channel — second Silvair controller |
| Silvair vendor model ID | `(0x0136 << 16) \| 0x0001` | Identifies switch elements for publication config |
| CTL transition time | 200ms (2 × 100ms steps) | LightCTLSet smooth transition |
| Proxy scan timeout | 15s | connectToProxy gives up after 15s |
| Config message timeout | 8s | sendConfig per-message fallback timeout |
| ProxyFilter ready poll | 5s (50 × 100ms) | Wait for FilterStatus after bearer open |
| Bluetooth ready poll | 5s | Wait for CBManagerState.poweredOn |
| Post-provisioning delay | 1s | Allow device to reboot into proxy mode |
| Inter-device delay | 400ms | Breathing room between provisioning devices |
| Send loop gap | 100ms | Minimum gap between CTL sends |
