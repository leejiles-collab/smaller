# Shipping Smaller

Everything that has to happen outside this repository, in the order it has to
happen. Written for someone who has never shipped an app before: every step is
either a click or a command, and nothing is assumed.

Your details, used throughout:

| | |
|---|---|
| Team ID | `PT3HD7UTA5` (Individual) |
| App bundle ID | `com.leejiles.smaller` |
| Share extension bundle ID | `com.leejiles.smaller.share` |
| App Group | `group.com.leejiles.smaller` |
| In-app purchase product ID | `com.leejiles.smaller.pro` |
| App Store name | `Smaller PDF` — "Smaller" was taken. The name under the icon is still Smaller; this is the listing name only. |

All four are already set in the project. `BundleConfig.swift` is the single
source for the identifiers and `project.yml` carries the team, so
`./Tools/generate-project.sh` regenerates a correctly configured project at any
time.

---

## Part A — in the browser: identifiers

1. Go to <https://developer.apple.com/account> and sign in.
2. Click **Certificates, Identifiers & Profiles**, then **Identifiers** in the
   left sidebar.
3. Click the blue **+** next to "Identifiers". Choose **App IDs**, click
   Continue, choose **App**, click Continue.
4. Description: `Smaller`. Bundle ID: select **Explicit** and type
   `com.leejiles.smaller`.
5. Scroll the Capabilities list and tick **App Groups**. Click **Continue**,
   then **Register**.
6. Click **+** again and repeat steps 3–5 for the extension: description
   `Smaller Share`, explicit bundle ID `com.leejiles.smaller.share`, tick
   **App Groups**, Continue, Register.
7. In the left sidebar the "Identifiers" dropdown at the top right of the list
   says "App IDs" — change it to **App Groups**. Click **+**.
8. Description: `Smaller`. Identifier: `group.com.leejiles.smaller`. Click
   Continue, then Register.
9. Go back to **Identifiers → App IDs** and click `com.leejiles.smaller`. Find
   **App Groups** in the capability list, click **Configure**, tick
   `group.com.leejiles.smaller`, click **Continue**, then **Save**.
10. Do the same for `com.leejiles.smaller.share`.

## Part B — in the browser: the App Store Connect record

11. Go to <https://appstoreconnect.apple.com> and sign in.
12. Click **Apps**, then the blue **+**, then **New App**.
13. Fill it in:
    - Platforms: **iOS**
    - Name: `Smaller PDF`. "Smaller" was already taken — names must be unique
      across the whole App Store. This is the name on the store listing, not
      the name under the icon, which is still Smaller.
    - Primary Language: **English (U.S.)**
    - Bundle ID: **com.leejiles.smaller**
    - SKU: `smaller-ios-01` (internal only, never shown to anyone)
    - User Access: **Full Access**
14. Click **Create**.

## Part C — in the browser: the in-app purchase

You can upload a TestFlight build without this, but the paywall will have no
price until it exists, so do it now.

15. In your new app, click **Monetization → In-App Purchases** in the sidebar,
    then the blue **+**.
16. Type: **Non-Consumable**. Reference Name: `Smaller Pro`. Product ID:
    `com.leejiles.smaller.pro` — this must match exactly, it is in the code.
    Click **Create**.
17. Under **Pricing**, click **Add Pricing** and choose **USD 12.99**. Save.
18. Under **App Store Localization**, click **+**, choose English (U.S.):
    - Display Name: `Smaller Pro`
    - Description: `Unlimited compressions, for ever. One payment.`
19. Under **Review Information**, upload any screenshot of the paywall — there
    is one at `/tmp/out/visual/ui-paywall.png` — and in the notes write:
    `Tap Select PDF, compress ten files, then the paywall appears.`
20. Save. Its status will read "Ready to Submit"; it goes live with your first
    approved release.

## Part D — in Xcode: signing

21. Open **Xcode → Settings → Accounts**, click **+**, choose **Apple ID**, and
    sign in with the Apple ID that owns the developer account. Close Settings.
22. In Terminal, run `./Tools/generate-project.sh` from the repository root,
    then `open Smaller.xcodeproj`.
23. In the left-hand file list click the blue **Smaller** project icon at the
    very top. In the target list, select the **Smaller** target.
24. Click the **Signing & Capabilities** tab.
    - **Automatically manage signing**: ticked.
    - **Team**: your name (Personal Team is *not* the right one — pick the entry
      matching `PT3HD7UTA5`).
    - Under **App Groups**, `group.com.leejiles.smaller` should be listed and
      ticked. If it is not, click **+ Capability**, add **App Groups**, then
      click **+** under it and type `group.com.leejiles.smaller`.
25. Select the **SmallerShare** target and repeat step 24 exactly.
26. The signing panel should now show no red errors on either target. If it says
    a profile could not be created, wait a minute and click **Try Again** —
    identifiers registered in Part A can take a moment to propagate.

## Part E — in Xcode: check it runs

27. At the top of the window, set the run destination to any simulator and press
    **⌘R**. The app should launch on the home screen.
28. **To exercise the purchase**, it must be run from Xcode: the scheme carries
    `Support/Smaller.storekit`, which only applies to Xcode-launched runs. Once
    running, compress ten files (or edit `CreditStore.freeCompressions` down to
    1 temporarily), and the paywall will show a real $12.99 price and complete a
    simulated purchase. Restore Purchases works against the same local store.
29. Plug in your iPhone, select it as the destination, press **⌘R**. Accept the
    "Untrusted Developer" prompt on the phone if asked
    (Settings → General → VPN & Device Management → trust your certificate).
    This is the fastest way to test the share extension: open Mail, long-press a
    PDF attachment, tap Share, then Smaller.

## Part F — archive and upload

30. At the top of the Xcode window, click the run destination and choose
    **Any iOS Device (arm64)**. Archiving is impossible with a simulator
    selected.
31. Menu bar: **Product → Archive**. This takes a few minutes.
32. The **Organizer** window opens when it finishes. Your archive is selected.
    Click **Distribute App**.
33. Choose **App Store Connect**, then **Distribute**.
    <br><br>
    **Do not choose "TestFlight Internal Only" unless you are certain this build
    will never be sold.** That option stamps the build `INTERNAL_ONLY`
    permanently. Such a build still uploads, still processes, still shows
    "Validated", and still installs through TestFlight — but it cannot be
    attached to an App Store version. The Add Build dialog simply does nothing
    when you pick it, with no error, and the API refuses with
    `ENTITY_ERROR.RELATIONSHIP.INVALID`. The audience type cannot be changed
    afterwards, so the only fix is a new upload with a higher build number.
    <br><br>
    App Store Connect distribution still puts the build in TestFlight, so
    choosing it costs nothing.
34. Xcode uploads. When it says "Complete", close the Organizer.
35. Wait for the "App Store Connect: Version 1.0 (1) has completed processing"
    email. Usually 5–15 minutes.

## Part G — install on your phone

36. In App Store Connect, open your app and click the **TestFlight** tab.
37. Click **Internal Testing** in the sidebar, then the **+** next to Testers.
38. Tick your own name and click **Add**. You will get an email.
39. On your iPhone, install **TestFlight** from the App Store if you do not have
    it, open it, and accept the invitation. Smaller appears; tap **Install**.
40. Open Mail, find a big PDF attachment, long-press it, tap **Share**, and
    choose **Smaller**. That is the flow the whole app exists for.

---

## Part H — when App Store Connect fights you

Everything below was learned the hard way on this app. It is faster than the UI
and it tells you things the UI does not.

### Talking to the API

An App Store Connect API key (Users and Access → Integrations, **App Manager**
role, one download only) plus a short ES256 JWT gets you everything below. The
key for this account is a `.p8` in `~/Downloads`; `*.p8` is gitignored because
this repo is public. Issuer and key IDs live with the key, not here.

Useful IDs for this app:

| | |
|---|---|
| app | `6801676770` |
| version 1.0 | `ab9bb93e-9d88-492a-8116-9a814deae9d3` |

### Attaching a build when the UI will not

The Add Build dialog silently refuses ineligible builds. The API says why:

```
GET   /v1/apps?filter[bundleId]=com.leejiles.smaller
GET   /v1/apps/{id}/appStoreVersions?filter[versionString]=1.0
GET   /v1/builds?filter[app]={id}&filter[version]=4
        &fields[builds]=version,processingState,buildAudienceType
PATCH /v1/appStoreVersions/{versionId}/relationships/build
        {"data":{"type":"builds","id":"<buildId>"}}
GET   /v1/appStoreVersions/{versionId}/build      ← read it back, always
```

Check `buildAudienceType` **before** attaching. `INTERNAL_ONLY` can never be
attached and cannot be changed after upload — `PATCH /v1/builds/{id}` rejects
the attribute outright.

### Waiting for a build

Poll the API rather than the email. The email says processing finished; it does
not say whether the build is eligible to sell, which is the part that bites.
A build takes a few minutes to appear at all, then a few more to process.

### Build history, so numbers are never reused by accident

| Build | What it was |
|---|---|
| 1 | Uploaded as TestFlight Internal Only. Permanently unsellable. Dead. |
| 2 | First attachable build. |
| 3 | Credit store fix — one count shared by app and extension. |
| 4 | Share extension says Share / Save elsewhere and opens a real share sheet. |

---

## Part I — recording a demo video for App Review

Guideline 2.1 asks for a screen recording of the app working. That needs the
free-compression counter in a chosen state, and the counter is deliberately
hard to move: App Group defaults *and* a Keychain mirror, and the Keychain copy
survives deleting the app.

Nothing outside the process can write another app's Keychain items, and a
Release build has no hook to do it from the inside — `--set-credits-used` is
`#if DEBUG` and must stay that way. So the sequence is:

1. Build and install the **Debug** build on the device.
2. `xcrun devicectl device process launch --device <id> --terminate-existing \
       com.leejiles.smaller --set-credits-used=<n>`
3. It writes a read-back of both stores to `Library/Caches/demo-credits.txt`.
   Pull it and check it, rather than assuming the write landed:
   `xcrun devicectl device copy from --device <id> --domain-type appDataContainer \
       --domain-identifier com.leejiles.smaller --user mobile \
       --source Library/Caches/demo-credits.txt --destination ./out.txt`
4. Reinstall the real build from TestFlight and record. The reset survives,
   because it lives in the shared Keychain item.

Record the working flow **before** the paywall clip. Going back the other way
costs another build swap.

### Reading the count without changing it

The shared count is readable from a connected device at any time:

```
xcrun devicectl device copy from --device <id> \
    --domain-type appGroupDataContainer \
    --domain-identifier group.com.leejiles.smaller --user mobile \
    --source "Library/Preferences/group.com.leejiles.smaller.plist" --destination ./g.plist
plutil -p ./g.plist       # com.smaller.creditsUsed
```

That is the defaults half only. The Keychain half stays unreadable from
outside, by design — `used` takes the larger of the two, so treat the number as
a floor.

### What to say in the reply to review

Name the fix. "Resubmitting with a video" reads worse than a specific defect
found and corrected, and it explains why the binary changed rather than only
the metadata. If the paywall appears in the video, get past it on camera with a
sandbox purchase or Restore — a wall with no visible way through is its own 2.1
rejection.

---

## If something goes wrong

**"No profiles for 'com.leejiles.smaller' were found"** — the App ID from Part A
step 4 was not registered, or Xcode is signed into a different Apple ID than the
one that owns it. Check Xcode → Settings → Accounts.

**"Missing App Group entitlement"** — Part A step 9 or 10 was skipped. The group
has to be *assigned* to each App ID, not merely created.

**The extension does not appear in the share sheet** — it only offers itself for
a single PDF. Sharing two files, or a photo, will not show it. On a fresh
install, iOS can take a minute to register it; rebooting the phone forces it.

**Upload rejected for a missing icon** — regenerate with
`./Tools/generate-project.sh`; the icon lives in `Assets.xcassets`.

**The Add Build dialog will not select a build** — the radio button does nothing
in any browser and there is no error message. The build is almost certainly
`INTERNAL_ONLY`, from choosing "TestFlight Internal Only" at step 33. Check it
with the App Store Connect API:
`GET /v1/builds/<id>?fields[builds]=buildAudienceType`. If it says
`INTERNAL_ONLY` the build can never be sold, the attribute is rejected for
update, and the fix is to bump `CURRENT_PROJECT_VERSION`, archive again, and
distribute via **App Store Connect**.

**The paywall shows no price** — expected everywhere except an Xcode-launched
run (step 28) and TestFlight. TestFlight builds use the real sandbox and will
show $12.99 once Part C is saved.

**The paywall shows no price in an Xcode run, and the console says
`ASDErrorDomain Code=509 "No active account"`** — the run is talking to the real
App Store because the local StoreKit configuration did not load. Check
**Product → Scheme → Edit Scheme → Run → Options**: if *StoreKit Configuration*
is red or None, the scheme's reference is not resolving. Two things have to be
true, and `generate-project.sh` now handles both: `Support/Smaller.storekit`
must be a member of the project (project.yml adds it with `buildPhase: none`,
which keeps a test-only file out of the shipped bundle), and the scheme's path
must be `../../../Support/Smaller.storekit` — Xcode resolves it from the
`.xcscheme` file, while XcodeGen writes it one level short.

---

## Store listing copy

**Description** (58 words):

> Smaller makes PDFs smaller so you can send them.
>
> Pick a file, choose how small, and get it back. A 27 MB slide deck becomes
> 2 MB. Text stays sharp and selectable.
>
> Works from the share sheet in Mail and Files. Everything happens on your
> iPhone. No account, no network, no ads.
>
> Ten free compressions, then one payment.

**Screenshots** — generated at 1320x2868 (6.9", the size App Store Connect
requires) in `/tmp/out/appstore/`:

| File | Caption |
|---|---|
| `01-send-it.png` | 27.8 MB → 2.1 MB. Send it. |
| `02-upload-it.png` | 27.2 MB → 1.6 MB. Upload it. |
| `03-every-pixel.png` | 75% smaller. Every pixel intact. |
| `04-under-5mb.png` | Need it under 5 MB? Say so. |

Every number on them is real output from the fixtures, screenshotted from the
running app. The second caption was specified as "13.1 MB → 1.9 MB" but no
fixture produces those numbers, and a store screenshot has to match what the app
actually did — supply that file and it can be regenerated.

**Privacy answers** in App Store Connect: *Data Collection* → **No, we do not
collect data from this app**. This matches `PrivacyInfo.xcprivacy`, which
declares no collection and no tracking.

**Export compliance**: already answered by `ITSAppUsesNonExemptEncryption` in
`Support/Smaller-Info.plist`, so no upload prompt appears.
