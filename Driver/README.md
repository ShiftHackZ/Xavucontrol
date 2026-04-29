# Xavucontrol Virtual Cable Driver

## Current driver direction

The first real virtual cable implementation should be a Core Audio Server Plug-In.

This path matches the app's current diagnostics:

- The device must appear in Core Audio as `Xavucontrol Virtual Cable`.
- It should expose an output side so macOS apps can send audio into the router.
- It may expose an input side for future monitor/capture workflows.
- The controller app already checks whether the virtual cable is installed and selected as the default system input/output device.

## Why not direct Core Audio routing

The current Core Audio process APIs can expose process/device state, but they do not provide a public PulseAudio-style operation for moving another app's live stream to a different hardware device. The virtual cable is therefore the capture point that makes real routing possible.

## First milestones

1. Add a Core Audio Server Plug-In target that registers `Xavucontrol Virtual Cable`. Started.
2. Make the plug-in expose a minimal stereo output stream. Started.
3. Connect the plug-in to the existing `RoutingRouterService` control-plane state.
4. Move the router into a helper/XPC service so the driver and app can communicate out of process.
5. Replace the current JSONL command log with live IPC once the helper is available.

## Xcode integration

The main Xcode project now contains a `XavucontrolVirtualCable` target/scheme next to the `Xavucontrol` app target. This keeps the app UI and driver code available from the same Xcode project while the driver source remains in `Driver/`.

When the `Xavucontrol` app is built in Debug, a run script builds the latest driver bundle and embeds it here:

```text
Xavucontrol.app/Contents/Resources/Drivers/XavucontrolVirtualCable.driver
```

The Setup tab installs that bundled copy into:

```text
/Library/Audio/Plug-Ins/HAL/XavucontrolVirtualCable.driver
```

The installer uses an administrator prompt, replaces the previous installed bundle, ad-hoc signs the driver, and restarts Core Audio.

## Local build

Run:

```sh
sh Driver/build.sh
```

The script produces:

```text
Driver/build/XavucontrolVirtualCable.driver
```

The current driver binary is a minimal HAL bundle with:

- a CFPlugIn factory for `kAudioServerPlugInTypeUUID`
- an `AudioServerPlugInDriverInterface`
- one virtual device object
- one stereo output stream object
- no-op IO callbacks

The built driver can be installed from the app's Setup tab after building/running the app from Xcode.

## Bundle identifiers

- App: `org.moroz.xavucontrol`
- Virtual cable plug-in: `org.moroz.xavucontrol.virtualcable`
- Future router helper: `org.moroz.xavucontrol.router`
