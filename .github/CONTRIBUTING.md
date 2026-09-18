# Contributing to OpenBattery

Thanks for being here. OpenBattery is a small, dependency-free SwiftUI menu bar
app, and it stays that way on purpose — the guidelines below are mostly about
keeping it small.

## Ground rules

These are the constraints the whole project is built around. A change that
breaks one of them will not be merged, however useful it is:

- **No dependencies.** No SPM packages, no CocoaPods, no Carthage. The app links
  system frameworks only.
- **OpenBattery reads, it does not write.** It never changes a system setting.
  The charge limit is macOS's own feature; the app only links to it.
- **No root, no privileged helper, no shelling out.** Everything comes from
  IOKit in-process — never by parsing `ioreg` or `pmset` output.
- **No polling loop.** IOKit notifications drive refreshes, and expensive reads
  only run when something on screen needs them. The app idles at about 18 MB and
  0 % CPU; keep it there.
- **Never invent a value.** If a reading is unavailable or implausible, it is
  skipped, not shown as a dash or a guess.

## Getting set up

You need macOS 14+, Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
git clone https://github.com/Im-Fran/openbattery.git
cd openbattery
make project   # generates OpenBattery.xcodeproj from project.yml
```

The Xcode project is generated and is **not** committed. Add files under
`Sources/` or `Tests/` and run `make project` again rather than editing the
project in Xcode.

Everyday commands:

| Command | What it does |
| --- | --- |
| `make build` | Build and sign the app (Release) |
| `make test` | Run the unit tests (Debug) |
| `make run` | Build, then relaunch the menu bar app |
| `make install` | Copy the app to `/Applications` |
| `make clean` | Remove `build/` and the generated project |

CI runs `make test` and `make build` with `CODE_SIGNING_ALLOWED=NO`, so both
must pass before a PR can land.

## Where things live

```
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

## Adding a battery reading

The raw values are full of traps — mixed temperature scales, ASCII dates that
look like huge integers, undocumented units. So:

1. Decode it as a **pure function** in `BatteryDecoding.swift`, taking the raw
   dictionary values and returning a typed result.
2. Add a test in `Tests/` with a fixture from real hardware.
3. Reject implausible values explicitly instead of passing them through.
4. Only then wire it into a snapshot, a view or the menu bar.

If you are unsure about a unit, surface the raw value next to the interpreted
one so a wrong assumption stays visible rather than becoming a confident lie.

## Branches and commits

Branch off `dev`, which is the default branch:

```sh
git checkout dev && git pull
git checkout -b feat/cycle-count-warning
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org),
written in the imperative:

```
feat(ui): add a cycle count warning to the Lifetime tab
fix(menubar): keep the separator out of an empty label
docs: explain how ManufactureDate is decoded
```

Common types here: `feat`, `fix`, `refactor`, `docs`, `test`, `build`, `ci`,
`chore`. Scopes follow the area touched (`ui`, `menubar`, `settings`,
`caffeine`, `window`, …).

## Opening a pull request

1. Make sure `make test` and `make build` pass.
2. Push your branch and open a PR against `dev`.
3. Fill in the PR template, and attach screenshots for anything visual —
   light and dark mode.
4. Keep the PR focused. Unrelated cleanups belong in their own PR.

## Reporting bugs and requesting features

Use the [issue templates](https://github.com/Im-Fran/openbattery/issues/new/choose).
For wrong readings, the output of `ioreg -arw0 -c AppleSmartBattery` from the
affected Mac is what makes the difference between a guess and a fix.

Security vulnerabilities go through [SECURITY.md](SECURITY.md) instead — never
a public issue.

## Code of Conduct

Taking part in this project means following the
[Code of Conduct](CODE_OF_CONDUCT.md).
