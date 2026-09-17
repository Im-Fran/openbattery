<div align="center">

# 🔋 OpenBattery

**A native macOS menu bar app that shows what your battery is actually doing.**

[![CI](https://img.shields.io/github/actions/workflow/status/Im-Fran/openbattery/ci.yml?branch=main&label=CI)](https://github.com/Im-Fran/openbattery/actions/workflows/ci.yml)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-5-orange)](https://swift.org)
[![License](https://img.shields.io/github/license/Im-Fran/openbattery)](LICENSE)

</div>

---

## 📖 Overview

macOS tells you a percentage. Your battery knows far more than that: how many
milliamp-hours it really holds, how many watts are flowing in and out right now,
how hot it has ever been, and when it was built. All of it sits in the
IORegistry, and none of it is visible without digging.

OpenBattery surfaces that data in the menu bar. It is a SwiftUI app with no
dock icon, no dependencies and no background polling loop — IOKit wakes it when
the power source changes, and the expensive reads only run when something on
screen actually needs them. It idles at about **18 MB** of memory and **0 % CPU**.

Everything comes straight from `AppleSmartBattery` and `AppleSmartBatteryPack`
via IOKit: no root, no privileged helper, no shelling out to `ioreg` or
`pmset`. OpenBattery reads, it does not write — including for the charge limit,
which macOS now handles itself (see [below](#-how-the-charge-limit-works)).

---

## ✨ Features

- **Configurable menu bar** — show or hide the battery icon, and pick which
  fields sit next to it: percentage, time remaining, charging status, battery
  watts, adapter watts, system watts, charge in mAh, temperature. Set it up
  under the gear button → **Menu Bar**.
- **Popover** — charge in % and mAh, time to full or empty, adapter input,
  battery flow and system load in watts, temperature, and Low Power Mode.
- **Battery Info window** — the full picture, grouped for reading.
- **Charge limit guide** — one click to macOS's own Charge Limit setting.
- **Launch at login** — via `SMAppService`, toggled from the popover.

Fields are joined with a separator in a fixed order, so the layout stays
predictable no matter which order you switch them on:

```
🔋 97% · +8.6 W · 4,991 mAh
```

Anything that is not available right now is skipped rather than shown as a dash —
an unplugged Mac has no adapter watts. Picking watts, mAh or temperature makes
the app read the detailed battery data on a 10 second timer (about 0.2 % CPU);
percentage, time remaining and charging status stay free.

What the Battery Info window shows:

| Group | Fields |
|---|---|
| Charge | percentage, mAh, status, time to full, time to empty, Low Power Mode, temperature |
| Power | battery watts (signed), system load, adapter input, voltage, current, adapter description / rating / V / A |
| Health | full charge capacity, design capacity, nominal capacity, health %, cycle count, manufacture date, age in days, serial number, gas gauge model |
| Lifetime log | average temperature, temperature range, max charge rate, max discharge rate, voltage range, total operating time, temperature record period |

---

## 🛠 Tech Stack

| Layer | Technology |
|-------|-----------|
| Language | Swift 5, deployment target macOS 14 |
| UI | SwiftUI (`MenuBarExtra`, `Window`, `Settings`) |
| Data | IOKit — `IORegistryEntryCreateCFProperty`, `IOPSNotificationCreateRunLoopSource` |
| Login item | ServiceManagement (`SMAppService`) |
| Project generation | [XcodeGen](https://github.com/yonaskolb/XcodeGen) from `project.yml` |
| Tests | XCTest |

---

## 📋 Requirements

- **macOS 14** or newer on **Apple Silicon** (Intel Macs are not supported)
- **Xcode** with the macOS SDK
- **XcodeGen** — `brew install xcodegen`

---

## 🚀 Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/Im-Fran/openbattery.git
cd openbattery
```

### 2. Set your signing team

The app is signed with your own Apple Development certificate. Find your team ID:

```bash
security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
```

The `OU=` field is your team ID. Put it in `project.yml`:

```yaml
settings:
  base:
    DEVELOPMENT_TEAM: YOUR_TEAM_ID
```

### 3. Build and run

```bash
make run
```

The battery icon appears in the menu bar. There is no dock icon and no window
at launch — the app is an `LSUIElement` agent.

---

## 🏗 Building and Installing

```bash
make build      # build and sign into build/Release/OpenBattery.app
make run        # build, then launch the menu bar app
make install    # copy to /Applications and launch
make test       # unit tests for the raw-value decoding
make uninstall  # remove the app from /Applications
make clean      # drop build/ and the generated Xcode project
```

Every target accepts `XCODEBUILD_FLAGS` for extra `xcodebuild` settings — that is
how CI builds without a signing certificate:

```bash
make test XCODEBUILD_FLAGS='CODE_SIGNING_ALLOWED=NO'
```

`make` regenerates `OpenBattery.xcodeproj` from `project.yml` whenever that file
changes, so the project is never committed.

---

## 🔌 How the charge limit works

macOS limits charging by itself, so OpenBattery does not. Expand **Limit
charging** in the popover and it walks you through it, then opens the right pane:

1. Open Battery settings.
2. Click the ⓘ button next to **Charging**.
3. Drag **Charge Limit** to 80, 85, 90 or 95 %.

This used to be the job of third-party tools that wrote SMC keys as root. On
current firmware that door is closed: the charge-limit keys (`bfF0`, `bfD0`,
`bfE0`) answer `kIOReturnNotPrivileged` even to root, because the system owns
them now. Shipping a privileged helper would add a launch daemon, an approval
prompt and a way to strand your battery on a stuck charge gate — to reach a
setting macOS already offers.

---

## 🔍 Notes on the raw values

The gas gauge is not self-describing. Three values needed decoding rather than
reading, and `BatteryDecoding.swift` documents each one:

- **`ManufactureDate`** looks like a huge integer (`57390245359923`) but its
  little-endian bytes are ASCII `DDMMYY`. If that fails, the `YYWW` code inside
  `MfgData` is used instead.
- **Temperatures mix scales inside one dictionary**: centi-Celsius for the live
  reading, deci-Celsius for the lifetime average, plain Celsius for the lifetime
  range. OpenBattery picks the scale by magnitude and rejects impossible values.
- **`TotalOperatingTime` has no documented unit.** It is read as hours, and the
  raw sample counter is shown beside it so a wrong assumption stays visible
  rather than becoming a confident lie.

These are exactly what `make test` covers, with fixtures taken from real
hardware.

---

## 📁 Project Layout

```
project.yml                     XcodeGen project definition
Makefile                        build · test · run · install
Sources/OpenBattery/
  OpenBatteryApp.swift          @main scene: MenuBarExtra + info window
  BatteryReader.swift           IORegistry reads (quick and detailed)
  BatteryDecoding.swift         pure decoding, shared with the tests
  BatterySnapshot.swift         one immutable reading, plus derived values
  BatteryMonitor.swift          IOKit notifications, refresh policy
  Formatting.swift              display formatting
  MenuBarConfig.swift           which fields the menu bar shows
  Views/                        menu bar label, popover, info window
Tests/                          decoding and menu bar configuration
```

---

## 🤝 Contributing

Contributions are welcome. Quick workflow:

1. Fork the repo
2. Create a branch: `git checkout -b feat/your-feature`
3. Make sure `make test` passes
4. Commit using [Conventional Commits](https://www.conventionalcommits.org):
   `git commit -m "feat: add your feature"`
5. Push and open a PR

If you are adding a field, decode it in `BatteryDecoding.swift` and cover it
with a test — the raw values are full of traps.

---

## 📄 License

This project is licensed under the **MIT License** — see the [LICENSE](LICENSE)
file for details.

---

<div align="center">
Made with ☕ by <a href="https://fsolism.cl">Fran</a>
</div>
