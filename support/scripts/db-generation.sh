#!/bin/bash
set -Eeuo pipefail

# --------------------------------------------------
# Global paths
# --------------------------------------------------
APP_DIR="${APP_DIR:-/app}"
RSSD_DIR="${RSSD_DIR:-/rssd}"
LOG_DIR="$RSSD_DIR/logs"
REPO_DIR="$APP_DIR/www.surveilr.com"

echo "===== SURVEILR PIPELINE STARTED ====="

# --------------------------------------------------
# Ensure base directories exist
# --------------------------------------------------

echo "Creating base directories..."
rm -rf "$APP_DIR" "$RSSD_DIR" "$LOG_DIR"
mkdir -p "$APP_DIR"
mkdir -p "$RSSD_DIR"
mkdir -p "$LOG_DIR"

# --------------------------------------------------
# Clone surveilr website repository (if not exists)
# --------------------------------------------------
echo "Ensuring surveilr website repository is present..."

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "Cloning surveilr website repository..."
  cd "$APP_DIR"
  git clone https://github.com/surveilr/www.surveilr.com.git
else
  echo "Repository already exists, skipping clone."
fi

# --------------------------------------------------
# Ensure index.tsv exists
# --------------------------------------------------
if [ ! -f "$RSSD_DIR/index.tsv" ]; then
  echo -e "expose_endpoint\trelative_path\trssd_name\tport\tpackage_sql" > "$RSSD_DIR/index.tsv"
fi

# ==================================================
# 1️⃣ PREPARE SCRIPTS
# ==================================================
echo "Running prepare scripts..."

mapfile -t PREPARE_PATHS < <(
  find "$REPO_DIR" -type f -name 'eg.surveilr.com-prepare.ts' -exec dirname {} \; 2>/dev/null
)

if [ "${#PREPARE_PATHS[@]}" -eq 0 ]; then
  echo "No prepare scripts found"
  exit 1
fi

for path in "${PREPARE_PATHS[@]}"; do
  relative_path="${path#$REPO_DIR/}"
  rssd_name="$(echo "$relative_path" | sed 's#/#-#g').sqlite.db"
  basename_path="$(basename "$relative_path")"

  cd "$path"

  if [ "$basename_path" = "site-quality-explorer" ]; then
    deno run -A ./eg.surveilr.com-prepare.ts \
      resourceName=surveilr.com \
      rssdPath="$RSSD_DIR/$rssd_name" \
      > "$LOG_DIR/$rssd_name.log" 2>&1

  elif [ "$basename_path" = "content-assembler" ]; then
    cat > .env <<EOF
IMAP_FOLDER=${EG_SURVEILR_COM_IMAP_FOLDER}
IMAP_USER_NAME=${EG_SURVEILR_COM_IMAP_USER_NAME}
IMAP_PASS=${EG_SURVEILR_COM_IMAP_PASS}
IMAP_HOST=${EG_SURVEILR_COM_IMAP_HOST}
EOF

    deno run -A ./eg.surveilr.com-prepare.ts \
      rssdPath="$RSSD_DIR/$rssd_name" \
      > "$LOG_DIR/$rssd_name.log" 2>&1
  else
    deno run -A ./eg.surveilr.com-prepare.ts \
      rssdPath="$RSSD_DIR/$rssd_name" \
      > "$LOG_DIR/$rssd_name.log" 2>&1
  fi
done

# ==================================================
# 2️⃣ FINAL SCRIPTS
# ==================================================
echo "Running final scripts..."

mapfile -t FINAL_PATHS < <(
  find "$REPO_DIR" -type f -name 'eg.surveilr.com-final.ts' -exec dirname {} \; 2>/dev/null
)

for path in "${FINAL_PATHS[@]}"; do
  relative_path="${path#$REPO_DIR/}"
  rssd_name="$(echo "$relative_path" | sed 's#/#-#g').sqlite.db"
  basename_path="$(basename "$relative_path")"

  cd "$path"

  if [ "$basename_path" = "direct-messaging-service" ]; then
    deno run -A ./eg.surveilr.com-final.ts \
      destFolder="$RSSD_DIR/" \
      > "$LOG_DIR/${rssd_name}_final.log" 2>&1
  fi
done

# ==================================================
# 3️⃣ PACKAGE.SQL.TS SCRIPTS
# ==================================================
echo "Running package.sql.ts scripts..."

mapfile -t PACKAGE_PATHS < <(
  find "$REPO_DIR" -type f -name 'package.sql.ts' -exec dirname {} \; 2>/dev/null
)

port=9000

for path in "${PACKAGE_PATHS[@]}"; do
  relative_path="${path#$REPO_DIR/}"
  rssd_name="$(echo "$relative_path" | sed 's#/#-#g').sqlite.db"
  package_sql="${relative_path}/package.sql.ts"

  chmod +x "$path/package.sql.ts"
  cd "$path"

  surveilr shell ./package.sql.ts \
    -d "$RSSD_DIR/$rssd_name" \
    >> "$LOG_DIR/$rssd_name.log" 2>&1

  echo -e "1\t${relative_path}\t${rssd_name}\t${port}\t${package_sql}" \
    >> "$RSSD_DIR/index.tsv"

  port=$((port + 1))
done

# ==================================================
# 4️⃣ COPY QUALITYFOLIO PACKAGE.SQL
# ==================================================
echo "Copying qualityfolio package.sql..."

TARGET_DIR="$RSSD_DIR/lib/service/qualityfolio"
SOURCE_DIR="$REPO_DIR/lib/service/qualityfolio"

mkdir -p "$TARGET_DIR"

mapfile -t PACKAGE_SQL_PATHS < <(
  find "$SOURCE_DIR" -type f -name 'package.sql' 2>/dev/null
)

for path in "${PACKAGE_SQL_PATHS[@]}"; do
  cp "$path" "$TARGET_DIR/"
done

echo "===== SURVEILR PIPELINE COMPLETED SUCCESSFULLY ====="
