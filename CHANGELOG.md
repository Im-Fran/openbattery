# Changelog

All notable changes to OpenBattery are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org). A release tag is `<version>+<build>`:
`1.3.0+4` ships version 1.3.0, build 4, to TestFlight and GitHub Releases.

## [1.3.0] - 2026-10-18

### Added

- **Batteries widget** for the iPhone and iPad Home and Lock Screens and the
  Mac desktop, showing the charge of every device on your iCloud account and
  laid out like the system's own Batteries widget. **Edit Widget** picks which
  devices it shows and in what order.
  ([#18](https://github.com/Im-Fran/openbattery/pull/18))
- **iCloud in Settings**: whether sync is working, when it last ran, a
  **Sync Now** button, and what iCloud holds for each device, with a way to
  delete a device's history. On the Mac under Settings → **iCloud**, on the
  phone in the new **Settings** tab.
  ([#16](https://github.com/Im-Fran/openbattery/pull/16))
- **Live on the same network**: while the apps are open, your Macs, iPhones and
  iPads on one network find each other and update each other's battery the
  moment it changes, without waiting for iCloud. Only devices on the same Apple
  Account can connect. ([#16](https://github.com/Im-Fran/openbattery/pull/16))
- A device's detail pairs its own charge with the health, cycle count and
  capacity a Mac last read of it, and warns when that reading is out of date.
  A phone with stale health asks a Mac nearby that can reach it to read it
  again. ([#16](https://github.com/Im-Fran/openbattery/pull/16))

### Changed

- A device appears once in the list, whether it was seen by cable, over the
  network or through iCloud. ([#16](https://github.com/Im-Fran/openbattery/pull/16))

### Fixed

- Every state of the Battery Info window fills the window.
  ([#16](https://github.com/Im-Fran/openbattery/pull/16))

## [1.2.0] - 2026-10-12

### Added

- The Mac app updates itself from GitHub Releases.
  ([#13](https://github.com/Im-Fran/openbattery/pull/13))
- The popover lists the apps using significant energy.
  ([#14](https://github.com/Im-Fran/openbattery/pull/14))

## [1.1.0] - 2026-10-11

The first tagged release.

### Added

- Menu bar app that reads the battery straight from IOKit: charge in % and
  mAh, time remaining, adapter, battery and system watts, temperature, cycle
  count and health. No root, no helper, no polling loop.
- Configurable menu bar: pick, reorder and hide the fields next to the icon.
- **Battery Info** window with tabs charting the charge of the last 12 hours
  and the capacity retained over the last 12 months.
  ([#1](https://github.com/Im-Fran/openbattery/pull/1))
- Battery of a connected iPhone or iPad, over USB or Wi-Fi.
  ([#6](https://github.com/Im-Fran/openbattery/pull/6))
- iPhone and iPad companion app, synced with the Mac through your own iCloud.
  ([#9](https://github.com/Im-Fran/openbattery/pull/9))
- Keep display awake toggle, launch at login, and a shortcut to macOS's own
  Charge Limit setting.
- The notarized Mac app is published as a DMG on GitHub Releases.
  ([#12](https://github.com/Im-Fran/openbattery/pull/12))

[1.3.0]: https://github.com/Im-Fran/openbattery/compare/1.2.0+3...1.3.0+4
[1.2.0]: https://github.com/Im-Fran/openbattery/compare/1.1.0+2...1.2.0+3
[1.1.0]: https://github.com/Im-Fran/openbattery/releases/tag/1.1.0+2
