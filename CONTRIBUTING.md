# Contributing to TinyUsage

Thanks for helping make local-first usage tooling better.

## Before you start

TinyUsage is source-only and targets Swift 6, iOS 18+, macOS 15+, XcodeGen and Xcode. It intentionally has no backend, analytics, CloudKit or proprietary push service.

For a normal simulator/macOS build:

```sh
brew install xcodegen
make bootstrap
make test
```

Physical-device builds require your own Apple Developer Team and App Group. Copy `Config/Developer.example.xcconfig` to `Config/Developer.xcconfig`, or run:

```sh
./scripts/configure-signing.sh YOUR_TEAM_ID com.example.tinyusage
```

The local file is ignored and must never be committed.

## Pull requests

- Explain the user-visible behavior and the privacy/security impact.
- Add or update tests for protocol, persistence, provider mapping and error paths.
- Keep official API, private endpoint, measured local and estimated local data separate.
- Never include credentials, provider responses, user paths, account identities or real screenshots.
- Run `make format-check`, `make generate-check` and `make test` before submitting.
- Keep changes focused; avoid unrelated generated-file churn.

Use Discussions for questions and ideas. Use Issues for reproducible bugs. Security-sensitive reports belong in `SECURITY.md`, never in a public issue.

## License

By contributing, you agree that your contribution is provided under the MIT License in `LICENSE`. There is no CLA.
