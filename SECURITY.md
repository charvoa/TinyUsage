# Security policy

TinyUsage handles provider credentials and local usage logs. Treat the collector as security-sensitive software.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for `charvoa/TinyUsage`. If private reporting is unavailable, open a minimal issue asking for a private contact; do not include exploit details, credentials, tokens, cookies, raw provider responses or user paths.

Please include the affected commit/version, platform, reproduction steps and the smallest sanitized diagnostic that demonstrates the issue.

## Security boundaries

- Credentials remain on macOS and are stored in Keychain.
- iOS receives normalized snapshots only.
- Bonjour traffic is authenticated with a temporary 256-bit pairing secret and TLS-PSK.
- Widgets never access Bonjour, providers or credentials.
- Private provider endpoints are opt-in and may change or stop working.
- Diagnostic exports are explicitly requested and redacted.

We will acknowledge valid reports, coordinate a fix, and publish a concise advisory when disclosure is safe.
