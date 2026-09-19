# Reading the battery of a connected Apple device

Date: 2026-09-18
Branch: `feat/devices-ios-battery-readings`

## Goal

Show the battery of an iPhone (and any other iOS/iPadOS device) connected over
USB or Wi-Fi in the Battery Info window: charge, cycle count, capacities,
health, temperature and voltage — the same readings OpenBattery already shows
for the Mac, from the same tabs.

## Non-goals

- Writing anything to the device. Every request is a read.
- Persisted history per device. The Mac's `SampleLog` files stay Mac-only;
  a device only keeps an in-memory log for as long as the window is open.
- Apple Watch, AirPods and Bluetooth accessories. They speak other protocols
  and macOS only exposes a percentage for them.
- Replacing Finder's pairing. We pair ourselves, but the device still has to be
  unlocked and trusted by a human.

## Constraints discovered before designing

These are not preferences; they are what the platform allows.

1. **Cycle count is only reachable through `lockdownd`.** There is no public
   API and no companion-app route: iOS does not expose `AppleSmartBattery` to
   App Store apps either. The path is `usbmuxd` → `lockdownd` →
   `com.apple.mobile.diagnostics_relay` → IORegistry, which is what
   coconutBattery does.
2. **The App Sandbox blocks it.** Connecting to `/var/run/usbmuxd` is a unix
   socket outside the container. The socket itself is `srw-rw-rw-`, so POSIX is
   not the obstacle — the sandbox is.
3. **The system pair record is unreadable.** `/var/db/lockdown/*.plist` is mode
   644 but returns `Operation not permitted`: the directory is TCC-protected and
   needs Full Disk Access. We generate our own pair record instead, so neither
   Full Disk Access nor root is required.
4. **First pairing must happen over USB.** `lockdownd` answers
   `PairingProhibitedOverThisConnection` to a `Pair` request arriving over the
   network. Wi-Fi can refresh a device that is already paired; it can never
   bootstrap one.

## Architecture

One protocol client over two transports, because `lockdownd` is identical on
both:

```
USB    → /var/run/usbmuxd (unix socket, plist protocol) → Connect(port 62078)
Wi-Fi  → usbmuxd also lists network devices (ConnectionType: Network,
         NetworkAddress: sockaddr) → TCP straight to that address:62078

                        ↓ identical from here

LockdownClient   QueryType → GetValue(DevicePublicKey, DeviceName, ProductType,
                 ProductVersion, UniqueDeviceID)
                 → Pair (first time) / ValidatePair (afterwards)
                 → StartSession → mutual TLS upgrade, mid-stream
                 → StartService("com.apple.mobile.diagnostics_relay")
                   (a second connection to the returned port, TLS again when
                    the reply sets EnableServiceSSL)

DiagnosticsRelay { Request: "IORegistry", EntryClass: "AppleSmartBattery" }
                        ↓
DeviceBattery.decode(dictionary) → BatterySnapshot      // pure, unit-tested
```

`BatterySnapshot` is reused unchanged. The device exposes the fields it already
has, so the four existing tabs render a device without being rewritten, and the
tabs that have nothing to show hide themselves the way the Lifetime tab already
does when a gauge has no lifetime log.

### Modules

Under `Sources/OpenBattery/Devices/`, one purpose each:

| File | Responsibility |
|---|---|
| `PlistChannel.swift` | A NIO channel that sends a plist and awaits its reply. Two framings: usbmux (16-byte header) and lockdown (4-byte big-endian length). Inserts the TLS handler mid-stream on request. |
| `USBMux.swift` | `ListDevices`, `Listen` (device attach/detach as an `AsyncStream`), `Connect(deviceID, port)`. Parses `NetworkAddress` into an IP for the Wi-Fi path. |
| `PairRecord.swift` | Generates root and host RSA-2048 keys and certificates, signs the device's public key, persists the record per UDID under Application Support, reloads it on later launches. |
| `LockdownClient.swift` | The lockdown request/response vocabulary, pairing, the TLS session, `StartService`. |
| `DiagnosticsRelay.swift` | The IORegistry query and `Goodbye` on close. |
| `DeviceBattery.swift` | Pure mapping from the IORegistry dictionary to `BatterySnapshot`. No I/O, so it is in the test target. |
| `DeviceSession.swift` | An actor owning one device's live connection: connect, poll, tear down. |
| `DeviceMonitor.swift` | `@MainActor ObservableObject`: the device list, the selected device, its snapshot and its error state. |

`Views/DeviceSourcePicker.swift` plus a small change in `BatteryInfoView` to
choose where the snapshot comes from.

### Dependencies

Four SwiftPM packages, all Apple's:

- `swift-nio`, `swift-nio-ssl` — mutual TLS inserted into an already-open
  connection. Network.framework cannot upgrade a live connection, and
  SecureTransport is deprecated and would force the private key through the
  keychain to build a `SecIdentity`.
- `swift-certificates`, `swift-crypto` (`_CryptoExtras` for RSA) — generating
  and signing the three certificates the pair record needs. Hand-rolled ASN.1
  is the alternative and is not worth maintaining.

## Pairing

`PairRecord` generates a 2048-bit RSA root (self-signed, `CA:TRUE`) and host
certificate, wraps the `DevicePublicKey` returned by `GetValue` in a third
certificate signed by the same root, and sends all three to the device with
`Pair`. The device shows "Trust this computer" and asks for its passcode. The
reply carries an `EscrowBag`, which we store so a locked device can still be
read later.

The record lands in
`~/Library/Application Support/OpenBattery/pairing/<UDID>.plist` together with
`HostID` and `SystemBUID` (both persisted uppercase UUIDs). Later launches send
`ValidatePair` and only re-pair when the device answers `InvalidHostID`.

Failure modes are states in the UI, not thrown-away errors:
`PasswordProtected` (unlock the device), `UserDeniedPairing`,
`PairingDialogResponsePending` (keep waiting), and
`PairingProhibitedOverThisConnection` (connect it by USB once).

## Data mapping

iOS `AppleSmartBattery` does not use the same units as macOS, which is the
whole reason `DeviceBattery.decode` exists and is tested:

| IORegistry key | Snapshot field | Note |
|---|---|---|
| `CurrentCapacity` | `percentage` | Percent on iOS, unlike the Mac |
| `AppleRawCurrentCapacity` | `currentCapacityMAh` | mAh |
| `AppleRawMaxCapacity` | `fullChargeCapacityMAh` | mAh; matches the Mac's `FccComp1` role, so `healthPercent` needs no change |
| `DesignCapacity` | `designCapacityMAh` | mAh |
| `NominalChargeCapacity` | `nominalCapacityMAh` | mAh |
| `CycleCount` | `cycleCount` | |
| `Temperature` | `temperature` | Hundredths of a degree |
| `Voltage` | `volts` | mV |
| `InstantAmperage` / `Amperage` | `amps` | mA, signed |
| `BatteryInstalled`, `IsCharging`, `ExternalConnected`, `FullyCharged` | the matching flags | |
| `Serial` | `serialNumber` | |
| `AvgTimeToEmpty`, `AvgTimeToFull` | `timeToEmpty`, `timeToFull` | Same sentinel handling as the Mac |

No `LifetimeData` and no `AdapterDetails` on iOS: the Lifetime tab hides itself
already, and the Power tab shows flow without adapter rows.

Device identity travels separately from the reading, in a `DeviceIdentity`
(UDID, name, product type, iOS version, transport).

## UI

A picker at the top of the Battery Info window: "This Mac" followed by every
device `usbmuxd` reports, each labelled USB or Wi-Fi. Selecting one swaps the
snapshot the tabs read; the tabs themselves do not change. The charge chart
shows the session's in-memory samples for a device, and says so rather than
pretending to a 12-hour history it does not have.

The picker is also where connection state lives — connecting, waiting for
trust, unlock the device, connect by USB once, or "device support needs the
direct download" when the socket is unavailable.

## Build flavors

One target, two configurations, and **runtime detection rather than `#if`** so
both builds contain the same code and the App Store build can explain itself:

| Configuration | Entitlements | Used by |
|---|---|---|
| `Debug` | `OpenBattery-Direct.entitlements` (no sandbox) | development, so devices work while debugging |
| `Release` | `OpenBattery.entitlements` (sandbox, unchanged) | App Store / TestFlight; `ci.yml` and `release.yml` stay as they are |
| `Release-Direct` | `OpenBattery-Direct.entitlements` | the notarized DMG, via the `release_github` lane |

The direct entitlements keep hardened runtime and add only
`com.apple.security.network.client`, needed for the Wi-Fi transport.

## Errors and lifetime

`usbmuxd`'s `Listen` pushes attach and detach events, so the device list never
polls. A selected device keeps one lockdown session and one relay connection
open while the window is visible, reusing the `detailClients` counter that
already starts and stops the Mac's timer, and polls on the same five-second
cadence. Losing the device, the session or the socket resets to a labelled
state in the picker and retries on the next attach.

## Testing

The pure parts are unit-tested, following the existing pattern of listing
I/O-free files in the test target: usbmux and lockdown framing round-trips,
`DeviceBattery.decode` against a captured real `AppleSmartBattery` dictionary
(units, percent-vs-mAh, signed amperage, missing keys), and that a generated
root → host → device chain validates.

The protocol against real hardware is not mocked: phase 0 is a throwaway CLI
run against a physically connected iPhone, and it is the gate for everything
after it.

## Phases

0. **Spike (throwaway).** A command-line probe that connects, pairs and dumps
   `AppleSmartBattery` from a connected iPhone. It settles the four risks below
   before a line of app code is written.
1. **Protocol in the app.** The modules above, the two build flavors, the tests.
2. **UI.** The picker, the device readings in the tabs, every connection state.
3. **Wi-Fi.** Network devices from `usbmuxd`, the TCP transport, the
   "pair by USB first" path.

## Risks

1. NIOSSL negotiating with `lockdownd` — client certificate, verification off,
   and an iOS that may insist on TLS 1.2.
2. The exact certificate shape the device accepts when pairing.
3. `Connect` takes its port big-endian inside a little-endian header.
4. `diagnostics_relay` still answering IORegistry queries on current iOS.

Each is resolved in phase 0, on hardware, before anything depends on it.
