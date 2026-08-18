# SCALLAPP.md

The Scallapp Partners chassis. Drop this in every repo. Claude Code reads it first, and it stops us re-explaining the same things fifty times.

---

## What we're doing

Find a job people already do badly on iPhone, usually because the good version is buried inside an app that also does nine other things and charges monthly for the privilege. Build only that one job, do it exceptionally well, charge once, ship, move on.

The model is volume, not jackpots. No single app has to win. Each one has to be cheap to build and honest about what it does.

## Non-negotiables

These are what make an app ours rather than another entry in a crowded category.

- **One job.** If the app needs a second screen to explain itself, the scope is wrong.
- **On-device.** No servers, no uploads, no accounts. This is the strongest thing we can say and it's only true if we never break it.
- **Zero third-party dependencies.** Apple frameworks only. If a dependency seems necessary, stop and say why rather than adding it.
- **One-time purchase.** Never a subscription. The pitch is "pay once, keep it," and it's the clearest differentiator in every category we enter.
- **No ads. Ever.**
- **A share extension** wherever the app responds to something rather than starting something. Most utilities are the second thing a person does, not the first.
- **Honest failure.** When the app can't do the job, it says so plainly and says what would fix it. Never produce a result the user will get rejected for and call it done.

## Banned

Onboarding carousels. Rating prompts. Countdown timers. Fake scarcity. "AI-powered" anything in copy. Streaks and gamification. Cloud sync. Document management. Feature lists that grow to justify a subscription.

## The build sequence

This is the order that worked on Smaller and it's the order every app should follow.

**1. Validate the wedge before building anything.** Build the engine and a command-line harness first. No UI until real files have gone through it and produced numbers you believe. On Smaller this caught two fundamental problems — one that would have shipped a broken app, one that revealed the app's actual differentiator.

**2. Test with real files, not generated ones.** Synthetic fixtures come out of the same library that reads them, so they're clean in exactly the ways real files aren't. The first two real PowerPoint decks broke an assumption that had survived every synthetic test. Fixtures should come from as many different producers as possible.

**3. Verify output by re-reading it from disk.** Never trust what you just wrote. Check dimensions, byte counts, format markers, colour profiles — whatever the spec claims. Verification caught real bugs on Smaller that every other check missed.

**4. Never trust a single measurement path.** If the tool that writes the file is also the tool that reads it back, it can be blind to its own failure in the same way twice. Find an independent check.

**5. Then the UI.** Four screens is usually the shape: pick, choose, work, result. Every screen except the first needs a way back.

**6. Then extension, purchase, ship.**

## The chassis

Lift these from Smaller rather than rebuilding. `~/dev/smaller` is the reference.

| Component | What to reuse |
|---|---|
| Package layout | Local `<App>Kit` package, app target, share extension, `Tools/<app>cli` harness |
| Project generation | `project.yml` + `Tools/generate-project.sh`, XcodeGen, team and prefix in one `BundleConfig.swift` |
| Target-size solver | The convergence pattern — measure, adjust, retry, cap the passes, report honestly when it bottoms out |
| Integrity gate | Re-open the output, verify it against the input, discard and return the original on failure |
| Temp workspace | `TempWorkspace`, cleans up after itself |
| Files handoff | Extension stages into the App Group, app files it into Documents on next launch. `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`, both required |
| Credit store | App Group count mirrored to Keychain, single named constant for the free tier |
| Purchase store | StoreKit 2 actor, `.storekit` test config, restore path |
| Share extension shell | UIKit fallback view under the SwiftUI host, watchdog, liveness breadcrumb in the App Group. Result screen offers the same actions, in the same words, as the app's own |
| Credit store scoping | App Group count mirrored to Keychain **with `kSecAttrAccessGroup` set to the app group**, plus a migration read for pre-existing unscoped items |
| Debug state hooks | `#if DEBUG` launch arguments that set counters for demos, writing a read-back of every store they touched to `Library/Caches` |
| Privacy + support pages | `docs/` on GitHub Pages, same structure, swap the specifics |
| Shipping guide | `SHIPPING.md`, numbered, browser and Xcode steps |

## Design

Shared foundation, distinct identity. They should look like tools from the same workshop, not copies of a template.

**Shared:** system font, `.rounded` for numeric displays, generous whitespace, full Dynamic Type, VoiceOver on every result. The payoff is a number or a state, and it's the biggest thing on the screen. Copy is plain and short — no exclamation marks, no "seamless," no "effortlessly."

**Per app:** accent colour, icon, and the composition of the result screen. Smaller's payoff is one number dropping. A spec-checker's payoff is a column of ticks. Same values, different picture.

**Icons:** flat ground, one bold mark, legible at 60px. No gradients, no skeuomorphism, no letter-only marks — a letter says the name, not the job.

## Traps already paid for

Every one of these cost real time. They should cost nothing again.

**TestFlight Internal Only permanently poisons a build.** It stamps `INTERNAL_ONLY`, the build uploads and processes and shows "Validated" and installs through TestFlight — and can never be attached to an App Store version. The Add Build dialog silently refuses it with no error. The audience type cannot be changed after upload and build numbers can never be reused. **Always distribute via App Store Connect**, which delivers to TestFlight anyway.

**A Keychain mirror is not shared just because the App Group is.** An item
written without `kSecAttrAccessGroup` lands in the target's *default* access
group, which is its own `application-identifier` — so the app writes to
`TEAM.com.x.app` and the extension to `TEAM.com.x.app.share`: two items, same
service, same account, each invisible to the other. It hides for months because
the App Group defaults are genuinely shared and normally lead, with both mirrors
trailing behind. It surfaces the first time one side is reset and the other is
not, and then it bites: a counter that takes `max(defaults, keychain)` and heals
upward will let the stale copy silently raise the shared count back. Pass
`kSecAttrAccessGroup: <app group id>` — iOS accepts an App Group identifier as a
keychain access group when the target holds that entitlement, so it needs no
Keychain Sharing capability and no provisioning change. Migrate on first read:
if the scoped item is absent, read the unscoped one and adopt it, or the update
forgives everybody's spent credits.

**App Store Connect rejects any image with an alpha channel.** Screenshots, review images, everything. `sips -s format jpeg` to flatten. Check with `sips -g hasAlpha` before uploading.

**Swift classes need module-qualified principal class names.** `NSExtensionPrincipalClass` must be `$(PRODUCT_MODULE_NAME).ShareViewController`. The bare class name resolves to nothing, the extension never instantiates, and the user gets a blank white sheet with no error anywhere.

**An extension cannot write to the app's Files folder.** Separate sandboxes. Stage into the App Group, let the app file it on next launch, and say so honestly in the UI rather than claiming the file is somewhere it isn't yet.

**A share extension is terminal — it cannot hand the file back.**
`completeRequest(returningItems:)` is an Action-extension pattern. Most hosts,
Mail included, discard whatever a *share* extension returns, so a button that
promises to attach the result will silently drop it. Present a real share sheet
instead, from the view controller the host installed (UIKit, not SwiftUI's
`ShareLink` — presentation from inside an extension has to come from the
installed VC). Use the same words as the app's own result screen: coming in
through the share sheet should not change what the buttons are called.

**A Release build has no back door, so plan the QA one deliberately.** Anything
that manipulates entitlement or counter state for demos and testing belongs
behind `#if DEBUG` and is therefore *absent* from TestFlight and App Store
builds — which is correct, and also means you cannot reset anything on the
build you are about to record. The dance is: install the Debug build, set the
state, verify it, reinstall the real build from TestFlight. State that lives in
the Keychain or the App Group survives the swap, which is what makes this work
at all.

**Verify device state by reading it back, and know which half you can see.**
App Group defaults are readable from a connected device with
`devicectl device copy from --domain-type appGroupDataContainer`. Keychain items
are not readable from outside the process, by design. If a counter takes
`max(defaults, keychain)`, anything you read externally is a *floor*, not the
answer — so have the debug path write its own read-back of both halves
somewhere you can fetch.

**Do not verify UI strings by grepping a Release binary.** Swift string literals
are not reliably findable with `strings` or `grep` in an optimised build: a
label that is definitely present can return zero matches. A zero there proves
nothing. Verify on a device or a simulator instead.

**`getDrawingTransform` never scales up.** Hand it a destination larger than the page and it centres at 1:1 with white margins. Write the transform explicitly.

**Filenames have spaces and parentheses.** iOS is full of "Scan 3.pdf" and "Report (final).pdf". Test with them.

**IAPs need price and availability set** before the version's build can be attached. An incomplete IAP blocks the whole submission with an unhelpful error.

**Set App Pricing to Free.** The IAP is the $12.99, not the download.

**Age rating: everything is No.** Unrestricted Web Access, User-Generated Content, and Social Media are all No for a utility that makes no network requests.

**Contact info is required and "Sign-in required" must be unchecked** in App Review Information, or the reviewer waits for credentials that don't exist.

**`phys_footprint` counts freed-but-dirty pages.** A climbing baseline across runs is usually allocator dirt, not a leak. Prove it with `leaks` and `vmmap` before optimising anything.

**A privacy manifest is only as true as somebody's grep.** Two errors survived
into `PrivacyInfo.xcprivacy` on Uploadable and nothing in Xcode or App Store
Connect noticed either:

- `UserDefaults(suiteName:)` on an App Group needs reason **`1C8F.1`**, not
  `CA92.1`. `CA92.1` is the app's own defaults. Every app here shares a counter
  between app and extension, so every app here will get this wrong by default.
- A category was declared that the app never calls (`DiskSpace`). Declaring an
  API you do not use is invisible and quietly makes the manifest a false
  statement — which matters when the privacy page cites the manifest as proof.

Re-derive each entry from `grep` over the sources before every submission, and
confirm the file is in *both* built bundles — being a project member without
`buildPhase: resources` compiles cleanly and ships nothing.

**A leftover app in the simulator puts `◀ OtherApp` in the status bar.** iOS
believes it launched you, so the back-breadcrumb names your *previous* app on
every screenshot. Terminate every other app of yours before capturing. Only
findable by reading a finished screenshot closely — the pipeline reports success.

**Write screenshot captions that state no numbers.** Every number a viewer sees
should be inside the screenshot, produced by the engine on the input photo. Then
swapping the photograph — which happens late, when the licensed stock arrives —
regenerates the numbers and cannot turn a caption into a false claim.

**Let ImageIO apply EXIF orientation. Do not hand-write the transform table.**
Uploadable had eight `CGAffineTransform` cases and **four were wrong** — every
one that swaps the axes (5, 6, 7, 8). Orientation 6 is what every iPhone portrait
photo carries, so this affected most real inputs, and it shipped. The output was
180° out; case 7 was malformed outright.

The fix is one option, not four transforms:

```swift
CGImageSourceCreateThumbnailAtIndex(source, 0, [
    kCGImageSourceCreateThumbnailFromImageAlways: true,
    kCGImageSourceCreateThumbnailWithTransform: true,      // <- does the whole job
    kCGImageSourceThumbnailMaxPixelSize: max(width, height),
] as CFDictionary)
```

Despite the name that is a full-resolution decode when the max size is the image's
own. The same call had been used for previews all along, which is why previews
were right while the saved file was upside down — the correct implementation was
already in the file, ten lines above the wrong one.

**Nothing downstream can catch this.** Dimensions are right, the EXIF tag is
correctly stripped, the byte count is in band, every verifier passes. There is no
way to know which way up a photograph belongs without looking at it. It reached a
customer because there was no pixel-level assertion anywhere.

**Test it with a marker and a table of corners.** Write a bright square into the
stored top-left, tag the file with each orientation, and assert which corner it
lands in. The expectations are *data read off the EXIF spec*, never a second
implementation of the transforms — a reimplementation just repeats whatever
mistake the first one made.

| flag | marker ends up |
|---|---|
| 1 | top-left |
| 2 | top-right |
| 3 | bottom-right |
| 4 | bottom-left |
| 5 | top-left |
| 6 | top-right |
| 7 | bottom-right |
| 8 | bottom-left |

**Check a rotation fix against an independent tool, not against your own other
output.** Comparing outputs to each other proves they agree, not that they are
right. Python's `ImageOps.exif_transpose` is a second opinion that shares no code
with yours.

**And when a new test fails on all eight cases identically, suspect the test.**
The first run of this one reported every orientation flipped vertically, because
it confused a `CGBitmapContext`'s buffer layout (row 0 is the top) with CG
drawing coordinates (y-up). A uniform failure across every case is a property of
the harness, not of eight independent code paths.

**Closures inherit actor isolation silently, and Swift 6 traps at runtime.** A
closure written inside a `@MainActor` context — every SwiftUI view method —
*inherits* main-actor isolation unless the API it is handed to declares the
parameter `@Sendable`. Nothing is written down. Nothing warns. When the framework
then runs that block on its own queue, Swift 6 verifies the inherited claim and
kills the process with `EXC_BREAKPOINT`.

This shipped in Uploadable build 1 and crashed the first time a human tapped
Save to Photos:

```
queue: com.apple.PHPhotoLibrary.changes
  _dispatch_assert_queue_fail
  _swift_task_checkIsolatedSwift
  closure #1 in closure #1 in DoneView.saveToPhotos()
  __102-[PHPhotoLibrary _performCancellableChanges:...]_block_invoke
```

**Do not audit this by grepping for `assumeIsolated`.** There was none — the
codebase contained zero. The isolation was *inferred*, which is precisely what
makes the bug invisible in review and invisible to the compiler.

Audit by finding every closure handed to a framework, then asking the compiler
which of them are Sendable. Put a reference to main-actor state inside the
closure and build:

- *"main actor-isolated property can not be referenced from a Sendable closure"*
  → the parameter is `@Sendable`, the closure does **not** inherit, it is safe.
- It compiles clean → the closure **did** inherit isolation, and it will trap the
  moment the framework runs it off the main actor.

On Uploadable that probe cleared `NSItemProvider.loadFileRepresentation`
(annotated `@Sendable` in the SDK) and convicted `PHPhotoLibrary.performChanges`
(not annotated). The fix is structural: move the work into a `nonisolated` type
so there is no isolation to inherit, rather than sprinkling `@Sendable` at call
sites.

**A screen you photograph is not a screen you have tested.** The screenshot
pipeline had rendered the Done screen dozens of times and never pressed a button
on it. 49 unit tests never touched Photos. The crashing path had literally never
executed anywhere before a real phone ran it.

**`#if DEBUG` cannot give you a TestFlight-only feature.** Archive builds
Release, and the TestFlight binary *is* the App Store binary — one upload, served
to testers and then released unchanged. Gate on a **sandbox receipt** at runtime
instead:

```swift
Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
```

Local, no network — unlike `AppTransaction.shared`, which matters if the privacy
page claims the app makes no network requests. Keep the decision in a function
that takes the filename so it is unit-testable, and make it fail closed.

Accept that the code ships and make it safe rather than hidden: bound the worst
case (a refilled free-usage meter is revenue, not damage), require a deliberate
gesture, and **label it on screen** — a secret control is one the tester cannot
find and nobody remembers to remove. Note that App Review also runs on a sandbox
receipt, so the honest claim is "unreachable by customers", not "unreachable in
production".

Anything that alters app state for testing must also be suppressed while store
screenshots are captured, since those are built Debug.

**Use the app yourself before shipping it.** Not the test suite, not the
screenshot pipeline, not a simulator driven by a script — sit down and do the
thing a customer would do, on the hardware they would do it on.

On Uploadable the first human session found three defects in about ten minutes,
after 47 green tests, a verified engine, ten generated screenshots and a fully
audited privacy manifest:

- Pinch-to-resize ran the wrong way. Fingers apart made the crop box smaller,
  because the code treated the gesture as zooming into the photo when the photo
  is fixed and the *box* is what the hand is on. Nothing measurable was wrong.
- The pinch was attached to the crop rectangle, so spreading fingers left the
  target immediately and it read as dead. Every automated pinch had been aimed
  at the centre of the rectangle, where it worked perfectly.
- The app produced a correct file from a photograph taken too close, and said
  nothing, because everything it checks was satisfied.

Every one of these is invisible to verification: the output was correct in all
three cases. Verification proves the thing you built does what you specified. It
cannot tell you the specification was wrong, and it cannot tell you the app is
unpleasant to hold.

**The IAP review screenshot needs 1290 x 2796. Not the listing size.** This has
now cost time on two apps, so: App Store Connect has **two** screenshot fields
with **different** accepted sizes, and the in-app purchase's Review Information
field is the older one.

| Field | Size |
|---|---|
| Version page, iPhone listing screenshots | **1320 x 2868** (6.9") |
| In-app purchase → Review Information | **1290 x 2796** (6.7") |

Hand the IAP field 1320x2868 and it fails with *"The dimensions of one or more
screenshots are wrong"* — which names no size, so it reads as a mystery rather
than a mismatch. Apple's help text for the field says 640 x 920 *minimum*, which
is true and actively misleading: clearing the floor is not sufficient.

The 6.7" devices are **iPhone 16 Plus, 15 Plus, 14/15 Pro Max**. iPhone 16 Pro
Max is 6.9", not 6.7" — an easy hour to lose. If no 6.7" simulator exists,
create one rather than resizing a 6.9" capture; the two aspect ratios differ
slightly, so a resize either distorts or letterboxes.

**When a size is disputed, read what Apple already accepted.** The
`appStoreReviewScreenshot` and `appScreenshots` resources both expose
`imageAsset.width/height` plus an `assetDeliveryState`. An artefact sitting at
`COMPLETE` in a shipped app is stronger evidence than any documentation page:

```
GET /v2/inAppPurchases/<id>/appStoreReviewScreenshot
GET /v1/appScreenshotSets/<id>/appScreenshots
```

**Listing screenshots: 1320 x 2868 IS accepted as the primary iPhone size.** A
6.5" drop zone showing itself means the 6.9" slot is empty, not that 6.5" is
required — 6.5" is the fallback, required only when 6.9" is absent. Uploaded 6.9"
files live in the `APP_IPHONE_67` set, because there is no `APP_IPHONE_69`.

**`simctl launch` ignores the scheme's StoreKit configuration.** The `.storekit`
file is a *launch action* setting that Xcode applies; a build installed and
launched with `simctl` talks to the real App Store, so an automated screenshot of
a paywall never renders a price. There is no `simctl storekit` subcommand. Either
accept the price-less capture for the IAP review field or retake it from
TestFlight once the product exists.

**Verify a DEBUG-only harness is absent from Release by behaviour, not grep.**
Grepping an optimised Swift binary for string literals proves nothing (above).
Install the Release build, pass it the launch argument the Debug build obeys, and
confirm it does nothing. That is a real check; a zero from `strings` is not.

**Derived app icons legitimately carry an alpha channel.** `actool` emits RGBA
home-screen PNGs from an opaque 1024 source, so `sips -g hasAlpha` says `yes` on
files inside a perfectly shippable bundle. What gets rejected is *transparency*,
not the channel — test `min(alpha) == 255` instead. The one file that must have
no channel at all is the 1024 marketing icon.

**Create the in-app purchase before you need it, and check by API that it
exists.** `GET /v1/apps/<id>/inAppPurchasesV2` returning zero items is the
difference between a working paywall and a Guideline 2.1 rejection. StoreKit code
that works perfectly against a local `.storekit` file will show no price and
refuse to sell against an empty App Store Connect. The product must also be
*attached to the version* — an unattached first-version IAP is never reviewed.

**Keywords: never repeat the name or the subtitle either.** Apple indexes both
already, so a term used there is dead weight in the 100 characters. This is more
expensive than it sounds — on Uploadable it ruled out `visa`, `passport` and
`photo`, the three most obvious terms — and it is still correct.

## Pricing

Free download. A usage-based free tier, not a time trial — usage tiers don't expire, so someone who tries it once still has credits waiting three months later when they hit the problem again.

Then one non-consumable, lifetime. $9.99–$12.99 depending on how urgent and how frequent the need is. Put the free-tier count in a single named constant so it's tunable without a hunt.

Paywall appears only when work is blocked. One sentence on what they get, a Restore Purchases button, clean dismissal.

## App Store listing

- **Name:** short, but check availability in App Store Connect first — the obvious ones are gone. Don't spend long here; nobody is searching for the name yet.
- **Subtitle:** this is where the search terms go. `Compress PDFs on your iPhone` does more work than the name.
- **Keywords:** 100 characters, comma-separated, no spaces, never repeat the app name.
- **Description:** lead with the problem in one line. No marketing language. State the price and the absence of a subscription.
- **Screenshots:** real numbers from real files, never mocked. Apple rejects misrepresentation, and we'd rather not claim results we can't reproduce. Largest size per family only.
- **Privacy:** answer no data collection, then **publish** it — saving isn't enough and it blocks submission.

## Candidate list

Keep this updated as ideas surface, so we're never researching from zero.

- Video to a target size, share-sheet first
- Strip GPS and EXIF from photos before sending
- Pull pages out of a PDF, or split one to fit a limit
- HEIC / PNG / Live Photo → a plain JPEG that any system accepts
- Scan a document straight to a size limit

## Working with Claude Code

- Read this file first.
- Say plainly when something in the brief is wrong or impossible, and what you did instead. On Smaller this was consistently the most valuable thing in every report.
- Measure before optimising. Two "obvious" memory fixes both made things worse and had to be reverted.
- One-line lowercase commits. No emoji, no generated-by footer.
- Build before claiming anything works.
- Don't stop to ask permission mid-task. Work the list, then report.
