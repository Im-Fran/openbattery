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
3. **The system pair record is unreadable directly — but usbmuxd will hand it
   over.** `/var/db/lockdown/*.plist` is mode 644 and still returns `Operation
   not permitted`: the directory is TCC-protected and needs Full Disk Access.
   usbmuxd, which does have access, answers `ReadPairRecord` with the whole
   record. So the app needs neither Full Disk Access nor a pairing flow of its
   own: a device trusted in Finder is a device OpenBattery can read, and one
   that has never been trusted stays unreadable until its owner taps Trust.
4. **First pairing must happen over USB.** `lockdownd` answers
   `PairingProhibitedOverThisConnection` to a `Pair` request arriving over the
   network. That pairing is macOS's to do, not ours; Wi-Fi only works for a
   device that has already been trusted over a cable.

## Architecture

One protocol client over two transports, because `lockdownd` is identical on
both:

```
usbmuxd  ListDevices        → devices over USB *and* over Wi-Fi: it proxies both,
         ReadPairRecord       so there is one transport, and it reads
         Connect(port 62078)  /var/db/lockdown for us

                        ↓

LockdownClient   QueryType
                 → StartSession → mutual TLS upgrade, mid-stream
                   (the record's *host* pair; TLS 1.2 at most)
                 → GetValue(DeviceName, ProductType, ProductVersion)
                 → StartService("com.apple.mobile.diagnostics_relay")
                   (a second connection to the returned port, TLS again when
                    the reply sets EnableServiceSSL)

DiagnosticsRelay { Request: "IORegistry", EntryClass: "AppleSmartBattery" }
                        ↓
DeviceBattery.decode(dictionary) → BatterySnapshot      // pure, unit-tested
```

There is no `Pair` and no `ValidatePair`: the first is macOS's job, and the
second is answered by hanging up. `StartSession` is the check that matters —
it reports `InvalidHostID` when a record is no good.

`BatterySnapshot` is reused unchanged. The device exposes the fields it already
has, so the four existing tabs render a device without being rewritten, and the
tabs that have nothing to show hide themselves the way the Lifetime tab already
does when a gauge has no lifetime log.

### Modules

Under `Sources/OpenBattery/Devices/`, one purpose each:

| File | Responsibility |
|---|---|
| `PlistChannel.swift` | A NIO channel that sends a plist and awaits its reply, under a deadline and cancellable. Two framings: usbmux (16-byte header) and lockdown (4-byte big-endian length). Inserts the TLS handler mid-stream on request. |
| `USBMux.swift` | `ListDevices`, `Connect(deviceID, port)`, `ReadPairRecord`. |
| `PairRecord.swift` | Reads the record usbmuxd hands over. No key generation, no storage of our own. |
| `LockdownClient.swift` | The lockdown request/response vocabulary, the TLS session, `StartService`. |
| `DiagnosticsRelay.swift` | The IORegistry query and `Goodbye` on close. |
| `DeviceBattery.swift` | Pure mapping from the IORegistry dictionary to `BatterySnapshot`. No I/O, so it is in the test target. |
| `DeviceSession.swift` | An actor owning one device's live connection: connect, poll, tear down. |
| `DeviceMonitor.swift` | `@MainActor ObservableObject`: the device list, the selected device, its snapshot and its error state. |

`Views/DeviceSourcePicker.swift` plus a small change in `BatteryInfoView` to
choose where the snapshot comes from.

### Dependencies

Two SwiftPM packages, both Apple's: `swift-nio` and `swift-nio-ssl`, for mutual
TLS inserted into an already-open connection. Network.framework cannot upgrade a
live connection, and SecureTransport is deprecated and would force the private
key through the keychain to build a `SecIdentity`.

The design originally called for `swift-certificates` and `swift-crypto` to
generate a pair record of our own. `ReadPairRecord` made both unnecessary — and
with them, a whole trust dialog, a key generator and a file to keep safe.

## Pairing

There is none. macOS has already paired every device its owner trusted in
Finder, and usbmuxd hands that record over on request. What the app does with it
is present the record's **host** certificate and key as its TLS credentials.

Failure modes are states in the UI, not thrown-away errors: no record at all
(nobody has tapped Trust), `PasswordProtected` (unlock the device),
`InvalidHostID` (trust this Mac again) and
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
| — | `temperature` | An iPhone does not publish one: the only temperature fields in the dump are zeroes in a boot-time payload, so the reading stays absent |
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

The device list is refreshed on the same five-second tick as the reading, by
asking usbmuxd over a local socket. `Listen` would push attach and detach events
instead, but its unsolicited messages would arrive on a channel built for
request and reply, and a local round trip every five seconds — only while the
window is open — is not worth that.

A selected device keeps one lockdown session and one relay connection open while
the window is visible, started and stopped by the same `detailClients` counter
that already drives the Mac's timer. A whole reading is bounded by one
twelve-second budget rather than a deadline per connection, so a locked phone
explains itself instead of spinning through three deadlines in series. Losing
the device leaves it in the picker with the failure showing, rather than
silently repointing every tab at the Mac.

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

0. **Spike (throwaway).** A command-line probe against a connected iPhone.
1. **Protocol in the app.** The modules above, the two build flavors, the tests.
2. **UI.** The picker, the device readings in the tabs, every connection state.
3. **Wi-Fi.** Came free with the transport: usbmuxd proxies network devices.

## Risks, and what the hardware said

Settled in phase 0 against an iPhone 16 Pro (iPhone17,1) on iOS 27.2:

1. **NIOSSL negotiating with `lockdownd`** — works, with two conditions found
   the hard way: the session must present the pair record's *host* certificate
   (with the root pair the device hangs up mid-handshake), and the client must
   cap at **TLS 1.2** (offered 1.3, the device drops the connection).
2. **The certificate shape a device accepts when pairing** — moot. We do not
   pair.
3. **`Connect`'s port byte order** — confirmed: big-endian inside a
   little-endian header.
4. **`diagnostics_relay` on current iOS** — alive, 48 keys of
   `AppleSmartBattery`.

Three more things the device taught us, each now a comment where it matters:
`ValidatePair` is answered by hanging up; every lockdown error closes the
connection, so a retry means a reconnect; and an iPhone leaves a stale
`AvgTimeToEmpty` in place while charging, where a Mac parks it on the 65535
sentinel — reading it blindly would put "2:10 left" on a charging phone.

Pinning the record's `DeviceCertificate` as a TLS trust root was tried and
reverted: it is a leaf, and BoringSSL will not anchor a chain on it. Verifying
the peer would need a custom verification callback; the ceiling is noted in the
code.
