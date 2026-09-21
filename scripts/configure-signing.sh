#!/bin/zsh
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
config_path="$root_dir/Config/Developer.xcconfig"

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <team-id> <reverse-dns-prefix>" >&2
  echo "Example: $0 ABC123XYZ com.example.tinyusage" >&2
  exit 2
fi

team_id="$1"
bundle_prefix="$2"
if [[ "$team_id" == *" "* || "$bundle_prefix" == *" "* || "$bundle_prefix" != *.* ]]; then
  echo "Team ID and bundle prefix must be non-empty values; prefix must be reverse-DNS." >&2
  exit 2
fi

umask 077
cat > "$config_path" <<EOF
// Generated locally. Never commit this file.
TINYUSAGE_BUNDLE_PREFIX = $bundle_prefix
TINYUSAGE_DEVELOPMENT_TEAM = $team_id
EOF

echo "Wrote $config_path"
echo "Register these identifiers with your Apple Developer account:"
echo "  $bundle_prefix.TinyUsageCollector"
echo "  $bundle_prefix.TinyUsage"
echo "  $bundle_prefix.TinyUsage.Widget"
echo "  group.$bundle_prefix.TinyUsage"
