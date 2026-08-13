# Smaller

An iOS app that compresses PDFs. That is the entire product.

No dependencies, no network, no accounts. Apple frameworks only.

## Layout

| path | what |
|---|---|
| `SmallerKit/` | Local Swift package: the engine. Both app targets use it. |
| `App/` | The iOS app. |
| `ShareExtension/` | Share extension. |
| `Tools/smallercli/` | macOS command-line harness for testing the engine. |
| `Fixtures/` | Real PDFs for testing. Gitignored. |

## Building

The engine and the CLI need nothing but Swift:

```sh
cd SmallerKit      && swift build && swift test
cd Tools/smallercli && swift build -c release
```

The Xcode project is generated, not committed:

```sh
brew install xcodegen     # once
./Tools/generate-project.sh
open Smaller.xcodeproj
```

The bundle identifier prefix lives in exactly one place:
`SmallerKit/Sources/SmallerKit/Models/BundleConfig.swift`. Change it there and
re-run the generator.

## Testing the engine

Drop real PDFs into `Fixtures/`, then:

```sh
Tools/smallercli/.build/release/smallercli report Fixtures/*.pdf --out /tmp/out > report.md
```

That runs every fixture against every profile plus 5 MB and 2 MB target-size
passes, and writes side-by-side page-1 renders to `/tmp/out/visual/`.
