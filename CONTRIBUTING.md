# Contributing

Build and test changes with:

```sh
swift build
swift test
sh Scripts/build-helper.sh
```

Do not commit generated binaries from `.build/`, `Plugin/bin/`, or `dist/`. Changes affecting
Accessibility, ScreenCaptureKit, input synthesis, signing, or MCP schemas require corresponding
tests and a security-impact note in the pull request.
