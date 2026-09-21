# Architecture

```text
Claude Code / Codex / provider APIs / local logs
                         │
                 TinyUsage Collector
          credentials, collection, normalization
                         │
                 Bonjour + TLS-PSK
                         │
                    TinyUsage iOS
          cache, dashboard, widget, Live Activity
```

The Mac is the credential owner. The iPhone is a display and limited refresh companion. A synchronized `SnapshotBundle` contains accounts, independent source metrics, provenance, freshness and source errors; it never contains credentials or raw provider responses.

## Boundaries

- `TinyUsageDomain` contains platform-neutral models, framing, persistence and presentation rules.
- `TinyUsageCollectorCore` contains provider connectors, credential resolution, local log scanning and aggregation.
- `TinyUsageCollector` owns Keychain, Application Support, Bonjour/TLS-PSK and menu-bar settings.
- `TinyUsage` owns pairing, App Group cache, dashboard and foreground/background synchronization.
- `TinyUsageWidget` only reads the App Group cache. It never contacts a provider or Bonjour.

Official API, private provider endpoints, measured local logs and estimated local costs remain structurally distinct. A failed source retains its last valid result and reports a separate error.

## Threat model

The design protects credentials from the iPhone, widgets, diagnostics and synchronized payloads. Local network access is authenticated after pairing, frames are length-bounded and versioned, and revocation removes the device PSK and closes active connections.

The design does not promise confidentiality from a compromised Mac, a compromised iPhone, or an attacker with access to either device's unlocked Keychain.
