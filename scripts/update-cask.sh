#!/bin/sh
# Writes Casks/splitroute.rb in the Homebrew tap for a release, from splitroute.rb.in, and pushes it.
# Usage: scripts/update-cask.sh <version> <sha256 of the DMG>
# Needs TAP_TOKEN (a fine-grained personal access token with Contents: read and write on the tap only) and,
# optionally, TAP_REPO (default split-route/homebrew-tap). TAP_DRY_RUN=1 prints the cask and pushes nothing.
set -eu
version=${1:?version}
sha=${2:?sha256}
repo=${TAP_REPO:-split-route/homebrew-tap}
here=$(cd "$(dirname "$0")/.." && pwd)

case $version in *[!0-9A-Za-z.+-]*) echo "bad version: $version" >&2; exit 1 ;; esac
case $sha in *[!0-9a-f]*) echo "bad sha256: $sha" >&2; exit 1 ;; esac
[ ${#sha} -eq 64 ] || { echo "sha256 must be 64 hex characters" >&2; exit 1; }

cask=$(sed -e "s/@VERSION@/$version/g" -e "s/@SHA256@/$sha/g" "$here/splitroute.rb.in")
if [ "${TAP_DRY_RUN:-}" = 1 ]; then printf '%s\n' "$cask"; exit 0; fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
token=${TAP_TOKEN:?TAP_TOKEN is not set}
git clone --quiet --depth 1 "https://x-access-token:$token@github.com/$repo.git" "$work/tap"
mkdir -p "$work/tap/Casks"
printf '%s\n' "$cask" > "$work/tap/Casks/splitroute.rb"
cd "$work/tap"
if git diff --quiet && [ -z "$(git status --porcelain)" ]; then
  echo "The cask is already at $version."
  exit 0
fi
git config user.name "splitroute-release-bot"
git config user.email "splitroute-release-bot@users.noreply.github.com"
git add Casks/splitroute.rb
git commit --quiet -m "splitroute $version"
git push --quiet origin HEAD
echo "Cask updated to $version."
