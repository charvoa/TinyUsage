# Privacy

TinyUsage has no TinyUsage server, analytics SDK, CloudKit database, proprietary push service or telemetry.

The collector reads only the provider credentials and local logs needed to calculate usage. Credentials stay in the macOS Keychain. The iPhone receives normalized metrics and source health; it does not receive tokens, cookies, raw responses, emails, organization identities or user paths.

Widgets read the local App Group cache. Live Activities update only after the app or an opportunistic system task synchronizes; they do not access the network themselves.

Provider names and trademarks describe compatibility only. TinyUsage is independent and unaffiliated with Anthropic and OpenAI.
