#!/bin/bash
set -e

DB_URL="$1"
if [ -z "$DB_URL" ]; then
    echo "Usage: $0 <database_url>"
    exit 1
fi

SRC_DIR="$(cd "$(dirname "$0")/../db/src" && pwd)"

for f in $(find "$SRC_DIR" -name "*.sql" | sort); do
    echo "Applying: $f"
    psql "$DB_URL" -v ON_ERROR_STOP=1 -f "$f"
done

echo "All src files applied successfully."
