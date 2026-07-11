# Shared version-derivation helper for ci/*.sh -- sourced, never executed
# directly. No CI script hardcodes a package version string; each derives it
# from debian/changelog's newest entry so the gates stay correct across
# milestones (see the M4 "version bump" task in docs/packaging-goal.md).
#
# Usage:
#   source "$REPO_ROOT/ci/version.sh"
#   VERSION="$(cloudberryos_version "$REPO_ROOT/debian/changelog")"

cloudberryos_version() {
  local changelog="${1:-debian/changelog}"
  sed -nE 's/^cloudberryos \(([^)]+)\).*/\1/p' "$changelog" | head -1
}

# cloudberryos_bump_patch <version> <n> -- bump the last dot-separated
# component of <version> by <n> (e.g. 0.2.0 + 1 -> 0.2.1). Used only to
# synthesize throwaway upgrade-test versions (never committed) relative to
# whatever the real current version is.
cloudberryos_bump_patch() {
  local version="$1" n="$2"
  awk -F. -v n="$n" -v OFS=. '{ $NF = $NF + n; print }' <<<"$version"
}
