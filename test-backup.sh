#!/usr/bin/env bash
# Self-check for backup.sh's risky invariants: the age encrypt→decrypt round-trip
# and the retention prune. Touches no postgres/R2. Requires: age.
set -euo pipefail
command -v age >/dev/null 2>&1 || { echo "SKIP: age not installed"; exit 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
key="$tmp/key.txt"
age-keygen -o "$key" 2>/dev/null
pub="$(grep -oE 'age1[0-9a-z]+' "$key" | head -1)"

# 1. encrypt → decrypt returns the exact bytes (incl. UTF-8)
printf 'SELECT 1; -- cärtei üml\n' > "$tmp/in.sql"
gzip < "$tmp/in.sql" | age -r "$pub" > "$tmp/out.sql.gz.age"
age -d -i "$key" "$tmp/out.sql.gz.age" | gunzip > "$tmp/back.sql"
diff "$tmp/in.sql" "$tmp/back.sql" || { echo "FAIL: round-trip mismatch"; exit 1; }

# 2. prune deletes expired, keeps recent
d="$tmp/backups"; mkdir -p "$d"
touch "$d/new.sql.gz.age"
touch -d '100 days ago' "$d/old.sql.gz.age"
find "$d" -maxdepth 1 -name '*.sql.gz*' -mtime +90 -delete
[ -f "$d/new.sql.gz.age" ] || { echo "FAIL: pruned a recent backup"; exit 1; }
[ ! -f "$d/old.sql.gz.age" ] || { echo "FAIL: kept an expired backup"; exit 1; }

echo "OK: age round-trip + retention prune"
