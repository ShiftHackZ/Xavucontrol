# Xavucontrol Virtual Cable Driver

This directory contains the Core Audio HAL plug-in used by Xavucontrol. It
exposes two Core Audio devices:

- `Xavucontrol Virtual Cable`: virtual output device used as the capture point
  for per-app playback routing.
- `Xavucontrol Virtual Mic`: virtual input device fed by Xavucontrol's
  microphone/playback mixer.

The driver is intentionally built as a single translation unit. Core Audio HAL
drivers are loaded into `coreaudiod`, so keeping one compiled unit avoids
visibility, initialization-order, and symbol-export surprises. For readability,
the implementation is split into include sections under `Driver/Sources`.

## File Structure

```text
Driver/
├── Info.plist
├── README.md
├── XavucontrolVirtualCable.cpp
├── build.sh
└── Sources/
    ├── DriverState.inc.cpp
    ├── AudioBuffers.inc.cpp
    ├── PropertyModel.inc.cpp
    ├── DriverCallbacks.inc.cpp
    ├── PropertyAccess.inc.cpp
    └── IOCallbacks.inc.cpp
```

### `XavucontrolVirtualCable.cpp`

Thin entrypoint compiled by `build.sh`.

It includes Core Audio headers, opens the driver's anonymous namespace, includes
the source sections, and exports `XavucontrolVirtualCableFactory`, the CFPlugIn
factory Core Audio uses to load the bundle.

### `Sources/DriverState.inc.cpp`

Defines driver-wide state:

- Core Audio object IDs for the plug-in, devices, streams, and controls.
- Public device names, UIDs, bundle ID, and model UID.
- Shared-memory diagnostics layout.
- Atomic counters and runtime state used by the IO callbacks.
- Output master volume/mute state for `Xavucontrol Virtual Cable`.

### `Sources/AudioBuffers.inc.cpp`

Contains helper functions and shared-memory audio handling:

- UUID matching and stream format helpers.
- Volume scalar/decibel conversion helpers.
- Shared diagnostics initialization and updates.
- Virtual cable playback buffer writes.
- Virtual mic input buffer reads.
- Lightweight serialization helpers for Core Audio property reads.

### `Sources/PropertyModel.inc.cpp`

Describes the driver's HAL object model:

- Which Core Audio object IDs represent plug-in/device/stream/control objects.
- Which properties each object supports.
- The data size for each supported property.
- Output volume/mute control discovery.

### `Sources/DriverCallbacks.inc.cpp`

Contains generic HAL callback dispatch:

- COM-style `QueryInterface`, `AddRef`, and `Release`.
- Driver initialization and device lifecycle stubs.
- `HasProperty`, `IsPropertySettable`, and `GetPropertyDataSize`.

### `Sources/PropertyAccess.inc.cpp`

Serializes property values and applies mutable driver state:

- Plug-in, device, stream, and control property reads.
- Sample-rate and buffer-size writes.
- Virtual Cable output volume/mute writes.
- Core Audio property-change notifications.
- Generic `GetPropertyData` and `SetPropertyData` entrypoints.

### `Sources/IOCallbacks.inc.cpp`

Implements real-time IO behavior:

- Start/stop lifecycle counters.
- Zero timestamp generation.
- IO operation negotiation.
- Output capture into the shared virtual cable buffer.
- Virtual microphone reads from the shared microphone buffer.
- `AudioServerPlugInDriverInterface` callback table.

## Documentation Style

C++ does not have JavaDoc built into the language. The closest common equivalent
is Doxygen-style comments:

```cpp
/**
 * @brief Short description.
 *
 * Longer details when the code needs context.
 */
```

The driver source sections use Doxygen file headers and short comments around
the major responsibilities. Keep comments focused on Core Audio behavior,
threading assumptions, shared-memory layout, and non-obvious HAL property
choices.

## Local Build

Run from the repository root:

```sh
sh Driver/build.sh
```

The script creates:

```text
Driver/build/XavucontrolVirtualCable.driver
```

The Xcode app target also runs this script and embeds the built driver into:

```text
Xavucontrol.app/Contents/Resources/Drivers/XavucontrolVirtualCable.driver
```

## Installation

The app's Setup tab installs the bundled driver into:

```text
/Library/Audio/Plug-Ins/HAL/XavucontrolVirtualCable.driver
```

The installer replaces the previous bundle, ad-hoc signs the driver, and
restarts Core Audio.

## Bundle Identifiers

- App: `org.moroz.xavucontrol`
- Driver bundle: `org.moroz.xavucontrol.virtualcable`
- Virtual cable UID: `org.moroz.xavucontrol.virtualcable.device`
- Virtual mic UID: `org.moroz.xavucontrol.virtualmic.device`
