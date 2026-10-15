# iCloud setup

One-time work on the Apple Developer portal so the Mac app and the iPhone app
can share readings through iCloud. Nothing here lives in the repository; the
entitlements files already ask for what these steps grant.

| | |
|---|---|
| iCloud container | `iCloud.cl.franciscosolis.openbattery` |
| App ID (macOS and iOS) | `cl.franciscosolis.openbattery` |
| Team | `PX7HA29NR3` (from `project.yml`) |

Both apps use SwiftData mirrored to the **private** CloudKit database of that
container. Nothing is written to the public database, so there is no server
cost and no data of anyone else's to look after.

## 1. Create the iCloud container

[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list/cloudContainer)
→ Identifiers → **+** → **iCloud Containers** → identifier
`iCloud.cl.franciscosolis.openbattery`, any description.

A container cannot be deleted or renamed afterwards, so check the spelling.

## 2. Enable iCloud and Push on the App ID

The Mac and iOS apps share one explicit App ID, `cl.franciscosolis.openbattery`,
so its capabilities are configured once for both platforms:

1. Identifiers → the App ID → Capabilities.
2. Tick **iCloud**, choose the CloudKit option (on older portal layouts this
   is "Include CloudKit support"), then **Configure** / **Edit** and select
   `iCloud.cl.franciscosolis.openbattery`.
3. Tick **Push Notifications**. CloudKit uses silent pushes to tell a device
   another one wrote something; no APNs certificate or key is needed for that.
4. Save. The portal warns that existing profiles become invalid — expected.

The iOS target uses Automatic signing: on the first device build Xcode makes an
iOS development profile for this same App ID, carrying the capabilities above.

## 3. Regenerate the provisioning profiles

Changing an App ID's capabilities invalidates every profile made for it.

**Mac, Developer ID** (the build that ships): the profile in the match repo
has to be recreated so it grants the iCloud container and push. From a machine
set up for `fastlane certificates` (see the README), force match to make a new
one:

```bash
bundle exec fastlane match developer_id --force
```

Run bare like this, match reads `fastlane/Matchfile` but signs in with an Apple
ID rather than the App Store Connect key the lanes use; pass
`--api_key_path <file.json>` (a JSON with `key_id`, `issuer_id` and
`key_filepath`) to use the key instead. Only the profile is recreated — the
Developer ID certificate itself stays as imported.

The sandboxed `Release` / App Store profile is invalidated too. Its
entitlements do not ask for iCloud, so it only needs regenerating if that build
is used again (`match appstore --force`).

**iOS**: while developing, Automatic signing makes the development profile on
the next Xcode build. For TestFlight and the App Store, `fastlane ios release`
signs with match's `match AppStore cl.franciscosolis.openbattery` profile
(created with `match appstore --platform ios`). Its entitlements file takes
`aps-environment` from the `APS_ENVIRONMENT` build setting — `development` in
Debug, `production` in Release — because each must match its profile.

**Mac Debug** builds carry no entitlements on purpose: a Mac app that claims
iCloud without a matching profile is killed at launch. Debug keeps its store
local.

## 4. Create the CloudKit schema in Development

SwiftData creates its record types (`CD_BatteryRecord` and friends)
automatically, but only in the **Development** environment and only from a
development-signed build. Run the iOS app from Xcode on a device signed into
iCloud (its entitlements use `aps-environment` = `development`), let it save a
reading, and the schema appears.

_Unverified:_ whether an ad-hoc signed simulator build from `make ios-run`
reaches CloudKit at all. A simulator run from Xcode with your team selected and
an iCloud account signed in should.

Then check [CloudKit Console](https://icloud.developer.apple.com/) →
`iCloud.cl.franciscosolis.openbattery` → Development → Schema → Record Types.

## 5. Deploy the schema to Production — before shipping

The Developer ID Mac build talks to **Production** only
(`com.apple.developer.icloud-container-environment` = `Production` in
`OpenBattery-Direct.entitlements`). Until the schema is deployed there, its
saves fail and nothing syncs.

CloudKit Console → the container → **Deploy Schema Changes…** → review →
Deploy.

**Check every field before deploying.** Development creates a field only when a
record is saved with a value in it, so an optional property that has only ever
been nil is missing from the schema. `relayedBy` is one: it is set only on a
reading a Mac took of an iPhone. If it never happened in Development, Production
rejects those records with "Cannot create or modify field 'CD_relayedBy'". Add
any missing field by hand in Development (Schema → Record Types →
`CD_BatteryRecord`), then deploy. The full list is `CD_date` (Date/Time),
`CD_deviceID`, `CD_deviceModel`, `CD_deviceName`, `CD_entityName`,
`CD_relayedBy` (String), `CD_payload` (Bytes) and `CD_percentage` (Int(64)).

Production schemas are additive: record types and fields can be added later
but never removed or renamed. Every model change that adds a property means
running a development build once more and deploying again before the release
that uses it.

An iOS build distributed through TestFlight or the App Store also uses
Production; a development build from Xcode uses Development. A development iOS
build and a Developer ID Mac therefore do **not** see each other — test the
Mac ↔ iPhone sync with both on the same environment.

## 6. Verify

Profile and signature of the shipped Mac app:

```bash
codesign -d --entitlements - build/OpenBattery.app
security cms -D -i build/OpenBattery.app/Contents/embedded.provisionprofile \
  | plutil -extract Entitlements xml1 -o - -
```

Both should list `iCloud.cl.franciscosolis.openbattery`, `CloudKit`,
`com.apple.developer.icloud-container-environment` = `Production` and
`com.apple.developer.aps-environment`. A Developer ID app whose profile is
missing an entitlement it claims will not launch.

Sync itself:

1. Install the notarized DMG build on a Mac signed into iCloud (System
   Settings → Apple Account → iCloud → iCloud Drive on; _unverified_ whether
   iCloud Drive specifically must be on for a CloudKit-only app).
2. Run the iOS app (Production environment, see above) on an iPhone with the
   same Apple ID.
3. Within a minute or so the Mac shows the phone under its devices and the
   phone's **Devices** tab shows the Mac. Pushes are best effort; bringing
   the app forward forces a fetch.
4. CloudKit Console → Production → Records → zone
   `com.apple.coredata.cloudkit.zone` in the private database shows the
   records of the account you sign into the console with. Querying may need a
   queryable index on `recordName`; add it under Indexes if the console asks.

If nothing arrives: Console → Logs shows rejected requests; `log stream
--predicate 'subsystem == "com.apple.coredata"'` on the Mac shows SwiftData's
mirroring errors; "Schema not deployed" or "invalid record type" means step 5
was skipped.
