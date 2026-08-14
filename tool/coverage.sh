#!/usr/bin/env bash
# Measure per-package line coverage and enforce the 90% floor (brief §6.13,
# §9). Usage: tool/coverage.sh <package-dir> [floor-percent]
#
# Runs the package's tests with coverage, converts the hitmap to LCOV, and
# fails with a nonzero exit if line coverage is below the floor. CI runs this
# for every package; it is also handy locally.
set -euo pipefail

pkg="${1:?usage: coverage.sh <package-dir> [floor]}"
floor="${2:-90}"
root="$(cd "$(dirname "$0")/.." && pwd)"
cov_dir="$(mktemp -d)"
trap 'rm -rf "$cov_dir"' EXIT

cd "$root/$pkg"
dart test --coverage="$cov_dir" >/dev/null

dart run coverage:format_coverage \
  --lcov \
  --check-ignore \
  --in="$cov_dir" \
  --out="$cov_dir/lcov.info" \
  --report-on=lib \
  --packages="$root/.dart_tool/package_config.json" >/dev/null

# Sum LCOV line-hit (LH) and line-found (LF) records across the report.
read -r hit found < <(awk -F: '
  /^LH:/ { hit += $2 }
  /^LF:/ { found += $2 }
  END { print hit, found }
' "$cov_dir/lcov.info")

if [[ "${found:-0}" -eq 0 ]]; then
  echo "coverage: no lines measured for $pkg" >&2
  exit 1
fi

pct=$(awk -v h="$hit" -v f="$found" 'BEGIN { printf "%.1f", (h / f) * 100 }')
echo "coverage($pkg): $pct% ($hit/$found lines)"

awk -v p="$pct" -v floor="$floor" 'BEGIN { exit !(p + 0 >= floor + 0) }' || {
  echo "coverage($pkg): below ${floor}% floor" >&2
  exit 1
}
