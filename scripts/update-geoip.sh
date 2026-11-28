#!/bin/sh
# Refreshes the country database the service embeds (DB-IP Lite Country, CC BY 4.0; see daemon/geo/NOTICE).
# DB-IP publishes one file a month: this takes the current month's, or the last one if it isn't out yet.
# Run it before a release, then `cd daemon && go test ./geo/` and commit the file.
set -eu
out="$(cd "$(dirname "$0")/.." && pwd)/daemon/geo/dbip-country-lite.mmdb.gz"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
for back in 0 1 2; do
  month="$(date -v-"$back"m +%Y-%m 2>/dev/null || date -d "-$back month" +%Y-%m)"
  if curl -fsSL -o "$tmp" "https://download.db-ip.com/free/dbip-country-lite-$month.mmdb.gz"; then
    gzip -t "$tmp"
    mv "$tmp" "$out"
    echo "geo database: $month ($(wc -c < "$out") bytes)"
    exit 0
  fi
done
echo "no DB-IP file found for the last three months" >&2
exit 1
