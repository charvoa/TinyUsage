#!/bin/zsh
set -euo pipefail

project_path="${1:-TinyUsage.xcodeproj}"
root_dir="$(cd "$(dirname "$0")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cp -R "$root_dir/$project_path" "$tmp_dir/committed.xcodeproj"
spec_dir="$tmp_dir/spec"
mkdir -p "$spec_dir"
cp "$root_dir/project.yml" "$spec_dir/project.yml"
for source in Config TinyUsage TinyUsageCollector TinyUsageCollectorCore TinyUsageCollectorTests TinyUsageDomain TinyUsageTests TinyUsageWidget; do
  cp -R "$root_dir/$source" "$spec_dir/$source"
done
(cd "$spec_dir" && xcodegen generate >/dev/null)
cp -R "$spec_dir/TinyUsage.xcodeproj" "$tmp_dir/generated.xcodeproj"

# XcodeGen versions can reorder the PBXProject target membership list while
# preserving the graph. Canonicalize only that unordered list; all other
# generated content remains byte-for-byte checked.
canonicalize() {
  python3 - "$1" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
pattern = re.compile(r"(PBXProject section.*?targets = \(\n)(.*?)(\n\s*\);)", re.S)

def normalize(match):
    lines = match.group(2).splitlines()
    target_lines = [line for line in lines if re.match(r"\s*[A-F0-9]{24} /\*", line)]
    other_lines = [line for line in lines if line not in target_lines]
    return match.group(1) + "\n".join(sorted(target_lines) + other_lines) + match.group(3)

updated, count = pattern.subn(normalize, text, count=1)
if count != 1:
    raise SystemExit(f"Could not find PBXProject target list in {path}")
path.write_text(updated)
PY
}

canonicalize "$tmp_dir/committed.xcodeproj/project.pbxproj"
canonicalize "$tmp_dir/generated.xcodeproj/project.pbxproj"
diff -u "$tmp_dir/committed.xcodeproj/project.pbxproj" "$tmp_dir/generated.xcodeproj/project.pbxproj"
