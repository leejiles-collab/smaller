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
| Share extension shell | UIKit fallback view under the SwiftUI host, watchdog, liveness breadcrumb in the App Group |
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

**`getDrawingTransform` never scales up.** Hand it a destination larger than the page and it centres at 1:1 with white margins. Write the transform explicitly.

**Filenames have spaces and parentheses.** iOS is full of "Scan 3.pdf" and "Report (final).pdf". Test with them.

**IAPs need price and availability set** before the version's build can be attached. An incomplete IAP blocks the whole submission with an unhelpful error.

**Set App Pricing to Free.** The IAP is the $12.99, not the download.

**Age rating: everything is No.** Unrestricted Web Access, User-Generated Content, and Social Media are all No for a utility that makes no network requests.

**Contact info is required and "Sign-in required" must be unchecked** in App Review Information, or the reviewer waits for credentials that don't exist.

**`phys_footprint` counts freed-but-dirty pages.** A climbing baseline across runs is usually allocator dirt, not a leak. Prove it with `leaks` and `vmmap` before optimising anything.

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
