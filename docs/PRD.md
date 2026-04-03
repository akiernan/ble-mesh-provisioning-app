# Product Requirements Document — BLE Mesh Provisioning App

## Overview

The BLE Mesh Provisioning App is an iOS tool for commissioning, configuring, and controlling Bluetooth Mesh lighting networks. It targets a single use case: bringing a set of Bluetooth Mesh lighting nodes (lights, dimmers, switches) into a named group and controlling them together from the iPhone.

The app handles the full lifecycle:

1. **Discovery** — Scan for unprovisioned BLE Mesh devices in range.
2. **Provisioning** — Admit each device to the mesh network with network/device keys.
3. **Key Binding** — Distribute the application key to each node and bind it to every non-config model.
4. **Group Configuration** — Create group address 0xC001, subscribe all lighting models to it, configure any switch/dimmer clients to publish to it.
5. **Device Control** — Operate the group (on/off, brightness, colour temperature) in real time.

On relaunch, if a provisioned network is already stored, the app skips directly to Device Control.

---

## Screens and User Flows

### 1. Device Discovery

**Entry point**: Root of the navigation stack.

**Purpose**: Scan for unprovisioned BLE Mesh devices and select which ones to commission.

**UI elements**:
- Header: wave icon, "Discover Devices" title, subtitle.
- **Bluetooth unavailable state**: `ContentUnavailableView` with an error message if Bluetooth is not powered on.
- **Pre-scan state**: A single "Start Scanning" button (blue gradient). Shown only when scanning has not yet started and no devices have been found.
- **Scanning state**: Device list appears with a spinner in the top-right. Each device shows:
  - Signal icon (green/blue/yellow/red based on RSSI thresholds).
  - Device name.
  - Signal strength label (Excellent / Good / Fair / Weak) and RSSI value in dBm.
  - Selection checkmark (blue filled when selected, grey empty when not).
- **Auto-selection**: Every newly discovered device is automatically selected. The user can tap a device row to deselect/reselect it.
- **Footer CTA**: Pinned to the bottom of the screen. "Continue with N device(s)" button. Disabled (grey) when no devices are selected. Active (blue gradient) when ≥1 device is selected.

**Interactions**:
| Action | Effect |
|--------|--------|
| Tap "Start Scanning" | Begins BLE scan for `MeshProvisioningService.uuid`. Devices appear as rows with slide-in animation. |
| Tap device row | Toggles selection. Row border and background update to reflect state. |
| Tap "Continue with N devices" | Stops scan. Saves selected devices to `meshService.selectedDevicesForProvisioning`. Navigates to Provisioning. |

**Navigation**: Forwards to `.provisioning`.

---

### 2. Provisioning

**Entry point**: Navigated to after device selection. Provisioning starts automatically on view appear.

**Purpose**: Admit each selected device to the mesh network. This is a non-interactive, automated screen.

**UI elements**:
- Header: shield icon (purple/pink), "Provisioning" title, subtitle.
- **Overall progress bar**: `ProgressView` showing `completedCount / totalDevices` with "N of M complete" label. Purple/pink gradient tint.
- **Per-device rows**: One row per selected device, in order. Each row shows:
  - State icon circle (grey/purple/green/red).
  - Device name.
  - State label: "Waiting" / "Connecting..." / "Provisioning..." / "Provisioned" / "Failed: …".
  - Percentage label (e.g. "70%") shown only when the device is `inProgress`.
  - Row border and background colour reflect state (purple when active, green when done, red on failure).
- **Success banner**: Green checkmark + "All devices provisioned successfully!" shown when `completedCount == totalDevices`.
- **Error text**: Red error message shown if any device fails.

**Provisioning states per device**:
```
pending (0%) → inProgress(0.2) → inProgress(0.4) → inProgress(0.7) → inProgress(1.0) → completed
```

**Automatic navigation**: 1 second after all devices complete, navigates to `.keyBinding`.

**Navigation**: Forwards to `.keyBinding` (back navigation hidden).

---

### 3. Key Binding

**Entry point**: Navigated to after provisioning completes. Key binding starts automatically on view appear.

**Purpose**: Establish secure communication by distributing the application key to all nodes and binding it to every non-configuration SIG model. This is a non-interactive, automated screen.

**UI elements**:
- Header: key icon (orange/yellow), "Key Binding" title, "Configuring secure communication" subtitle.
- **Configuration progress bar**: Shows completed step count ("N of 4 steps"). Orange/yellow gradient.
- **Step rows**: Four steps displayed in order, each with:
  - State icon circle (44×44, grey/orange/green/red).
  - Step title and description.
  - Row background and border colour matching state (orange when active).
  - Step-specific icons when pending (antenna, key, lock, sliders).
- **Per-device sub-rows**: Shown below the `.distributeKeys` OR `.configureModels` step **only while that step is `.inProgress`** and there are node states to show. Each sub-row shows:
  - Small state icon (24×24).
  - Node name.
  - State label: "Waiting" / "Sending…" / "Done" / error message.
  - Sub-row border and background in matching colour.
- **Security info card**: Blue card describing AES-CCM encryption. Always visible.
- **Completion badge**: Green "Key binding completed!" badge, shown when all 4 steps are `.completed`.
- **Error text**: Red error message if key binding fails.

**Step sequence**:
| Step | Title | What happens |
|------|-------|-------------|
| `.connectProxy` | Connect to Proxy | 2s delay after provisioning, then GATT proxy scan and connection. |
| `.generateKey` | Generate Application Key | Retrieves or creates a 128-bit AES app key. 300ms pause for visual feedback. |
| `.distributeKeys` | Distribute Keys | For each node: fetches composition data (if no models yet), then sends `ConfigAppKeyAdd`. Per-device sub-rows shown. |
| `.configureModels` | Configure Models | For each node: sends `ConfigModelAppBind` for every non-config SIG model on every element. Per-device sub-rows shown. |

**Automatic navigation**: After all steps complete, navigates to `.groupConfig`.

**Navigation**: Forwards to `.groupConfig` (back navigation hidden).

---

### 4. Group Configuration

**Entry point**: Navigated to after key binding completes. User must tap "Create Group" to start.

**Purpose**: Create a mesh group at address 0xC001, subscribe all lighting models, and configure any switch clients to publish to the group.

**UI elements (setup form)**:
- Header: persons icon (green/teal), "Group Configuration" title, subtitle.
- **Devices in Group card**: Lists all provisioned devices, each with a green "Ready" badge.
- **Room Name field**: Text input pre-filled with "Living Room".
- **Quick Select grid**: 3-column grid of room name chips (Living Room, Bedroom, Kitchen, Office, Bathroom, Hallway). Tapping a chip sets the room name field. The selected chip is highlighted in teal.
- **Create Group button**: Blue/green gradient. Disabled (grey) if room name is empty.

**UI elements (configuring state)** — shown after "Create Group" is tapped:
- **Setup Progress bar**: "N of M devices" label and a green/teal progress bar.
- **Per-device rows**: One row per provisioned device plus one for "This Device" (the iPhone's local node). Each row shows:
  - State icon (grey/teal/green/red).
  - Node name.
  - State label: "Waiting" / "Configuring…" / "Done" / error message.

**Interactions**:
| Action | Effect |
|--------|--------|
| Type in room name field | Updates room name; "Create Group" button enables/disables accordingly. |
| Tap a Quick Select chip | Sets room name to that value. Chip highlights in teal. |
| Tap "Create Group" | Starts group configuration. Form replaced with progress view. |

**Configuration sequence**:
1. For each provisioned node:
   - Primary lighting element (contains `LightCTLServer` or `LightLightnessServer`): subscribe CTL lightness binding models to **0xC001**.
   - CTL temperature element (contains `LightCTLTemperatureServer`): subscribe CTL temp binding models to **0xC002** (not 0xC001). Isolating this element prevents any Generic Level client addressed to the main group from inadvertently driving colour temperature.
2. For each element containing the Silvair vendor model (CID 0x0136, Model 0x0001):
   - Configure `GenericOnOffClient` and `GenericLevelClient` in that element to publish to **0xC001** (TTL=5).
   - Configure the `GenericLevelClient` in the **immediately following element** (element+1) to publish to **0xC002**. This allows the switch's second physical controller to drive colour temperature independently. The `GenericOnOffClient` in element+1 is left unconfigured.
3. For the local node (the iPhone):
   - Element 0 server models: bind app key and subscribe to **0xC001**, enabling receipt of lightness/on-off commands from external switches/dimmers.
   - Element 1 (`GenericLevelServer` + `GenericDefaultTransitionTimeServer`): bind app key and subscribe to **0xC002**, enabling receipt of colour temperature level commands from the switch's second controller.

**Post-completion**: Reconnects to proxy, then navigates to `.deviceControl`.

**Navigation**: Forwards to `.deviceControl` (back navigation hidden).

---

### 5. Device Control

**Entry point**: Navigated to after group config, or directly on relaunch if a network exists.

**Purpose**: Operate the mesh group in real time — power, brightness, and colour temperature.

**UI structure**:
- **Dark header bar** (gradient from dark grey):
  - Lightbulb icon in frosted tile.
  - Group name (from `MeshGroupConfig.name`) in bold.
  - Device count subtitle ("N device(s)").
  - Reset button (↺ icon, top-right): opens a confirmation alert.
- **Scrollable content area**:
  - Power section.
  - Sliders section (conditionally visible).
  - Individual Devices accordion.
  - Mesh info card.
  - Error message (if present).

#### Power Section

- Card with "Power" label (SF Symbol `power`).
- **CTL Toggle**: Custom 80×40 capsule toggle. Blue/cyan gradient when on, grey when off. White circle thumb slides left/right with spring animation.
- Tapping the toggle sends `GenericOnOffSetUnacknowledged` to group address 0xC001. `currentGroup.isOn` is updated immediately after send.

#### Sliders Section

Visible only when the group is `isOn`. Opacity 0.4 and disabled when `isOff`.

**Brightness Slider**:
- Label: "Brightness" with sun icon. Current value shown as "N%" (integer, monospaced).
- `Slider` in range 0–1, step 0.01. Blue/cyan gradient tint.
- Scale labels: "0%", "50%", "100%".
- Moving the slider updates `currentGroup.lightness` immediately (optimistic UI) and queues a `LightCTLSetUnacknowledged` message. Sends include the current temperature value.
- Clamped to device's `lightnessRangeMin`/`lightnessRangeMax` (retrieved from `LightLightnessRangeGet` on connect). Min defaults to 1% so the slider never sends lightness=0 (off).
- Zero lightness sends 0 (off). Any lightness > 0 while `isOn == false` also sets `isOn = true`.

**Colour Temperature Slider**:
- Label: "Color Temperature" with thermometer icon. Current value shown as "NNNNk" (monospaced) plus a text label (Warm / Neutral Warm / Neutral / Cool / Daylight).
- **Custom visual**: A warm-to-cool gradient track (amber → yellow-white → blue-white → deep blue) rendered as a `RoundedRectangle` beneath a transparent `Slider`.
- Range: device's `temperatureRangeMin`/`temperatureRangeMax` (from `LightCTLTemperatureRangeGet`). Defaults: 800–20000K.
- Scale labels: min K ("Warm"), midpoint K, max K ("Cool").
- Moving the slider updates `currentGroup.temperature` immediately and queues a `LightCTLSetUnacknowledged`.
- Sends include the current lightness value.

**Send rate limiting** (ACK-gated): A `sendLoop` drains pending lightness/temperature values one at a time, with a minimum 100ms gap between sends. Only the most recent pending value is ever sent — intermediate positions during fast slider moves are discarded.

**Transition time**: All CTL messages use a 200ms transition time (2 steps × 100ms).

#### Individual Devices Accordion

- Collapsed by default. Tapping the header toggles open/closed with spring animation.
- When open: lists all provisioned nodes by name (`meshService.provisionedNodes.map { $0.name ?? "Mesh Node" }`).
- Each row: coloured dot (green if group is on, grey if off), device name, "Connected" capsule badge.

#### Mesh Info Card

- Blue info card: "Mesh Network Active" (or "Connecting...") with description of simultaneous broadcast.
- `isConnected` tracks whether the GATT proxy bearer is open.

#### Reset

- Tapping ↺ in the header shows an alert: "Reset Mesh Network? / This will delete all provisioned devices and start over."
- Confirming triggers `factoryResetAllNodes()`, which:
  1. Shows a full-screen reset overlay with a linear progress bar ("N of M") and spinner.
  2. Sends `ConfigNodeReset` to each node sequentially.
  3. Deletes `MeshNetwork.json`.
  4. Resets all observable state.
  5. Calls `router.popToRoot()` — returns to Device Discovery.

---

## Progress Mechanisms

### Provisioning progress (per device)
State machine: `pending → inProgress(0.2) → inProgress(0.4) → inProgress(0.7) → inProgress(1.0) → completed`.
- Overall bar = `(completedCount + currentDeviceProgress) / totalDevices`.

### Key binding progress (per step)
Progress bar = `completedSteps / 4`, where an `.inProgress` step counts as 0.5.
Per-step, the `.distributeKeys` and `.configureModels` steps both show per-device sub-rows (one sub-row set at a time, reset between steps).

### Group config progress (per operation)
Total config operations are counted upfront (one per `ConfigModelSubscriptionAdd` or `ConfigModelPublicationSet`). Each completed send increments the counter and updates `groupConfigProgress = completedOps / totalOps`. Shown as "N of M devices" based on node state.

---

## State Persistence

- The mesh network topology (keys, nodes, groups, model bindings) is persisted in `MeshNetwork.json` in the app's Documents directory by `manager.save()`.
- `restoreStateFromNetwork()` is called at init. If a group at 0xC001 exists and remote nodes are present, `currentGroup` and `provisionedNodes` are restored and the app skips to Device Control.
- Actual device state (on/off, lightness, temperature) is NOT persisted — it is always queried from the device on connect via `fetchCurrentState()`.

---

## External Device Interaction

The app interoperates with Silvair-compatible switches and dimmers. The message destination determines whether a command controls brightness or colour temperature.

### Main group (0xC001) — brightness / on-off

- **On/Off switches**: Send `GenericOnOffSetUnacknowledged` to 0xC001. Updates `currentGroup.isOn`; the power toggle reflects the change.
- **Dimmers (absolute level)**: Send `GenericLevelSetUnacknowledged` or `GenericLevelSet` (acknowledged) to 0xC001. Level [-32768, 32767] → lightness: `lightnessRaw = UInt16(level + 32768); lightness = lightnessRaw / 65535`. Brightness slider reflects the change.
- **Dimmers (relative delta)**: Send `GenericDeltaSetUnacknowledged` (opcode 0x820A) to 0xC001. Delta applied to current lightness level: `newLevel = clamp(currentLevel + delta, −32768, 32767)`. Brightness slider reflects the change.

Received because the iPhone's local element 0 server models are subscribed to 0xC001 during group configuration.

### CTL temperature group (0xC002) — colour temperature

- **Second Silvair controller (absolute level)**: Sends `GenericLevelSetUnacknowledged` or `GenericLevelSet` to 0xC002. Level [-32768, 32767] maps linearly to the device's discovered temperature range `[temperatureRangeMin, temperatureRangeMax]`. The colour temperature slider reflects the change.
- **Second Silvair controller (relative delta)**: Sends `GenericDeltaSetUnacknowledged` to 0xC002. Current temperature is converted to an equivalent level value, the delta is applied, and the result is converted back to Kelvin using the same linear mapping. Colour temperature slider reflects the change.

Received because the iPhone's local element 1 `GenericLevelServer` is subscribed to 0xC002 during group configuration.
