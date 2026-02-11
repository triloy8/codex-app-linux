#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: $0 --dmg <file.dmg> [--electron-version <version>] [--arch <x64|arm64>] [--out <output-dir>]

Examples:
  $0 --dmg Codex.dmg --electron-version 40
  $0 --dmg Codex.dmg --electron-version 40.0.0 --arch x64 --out ./dist
USAGE
}

log() {
  printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(date +'%H:%M:%S')" "$*" >&2
}

get_module_version() {
  local mod="$1"
  local pkg=""
  if [[ -f "$APP_UNPACKED_SRC/node_modules/$mod/package.json" ]]; then
    pkg="$APP_UNPACKED_SRC/node_modules/$mod/package.json"
  elif [[ -f "$APP_SRC/node_modules/$mod/package.json" ]]; then
    pkg="$APP_SRC/node_modules/$mod/package.json"
  fi

  if [[ -z "$pkg" ]]; then
    return 1
  fi

  node -e "const fs=require('fs');const p=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));process.stdout.write(p.version||'');" "$pkg"
}

install_fresh_module() {
  local mod="$1"
  local version="$2"
  local build_root="$WORK_DIR/native-mod-build/$mod"
  local build_pkg="$build_root/package.json"
  mkdir -p "$build_root"

  cat > "$build_pkg" <<EOF
{
  "name": "native-rebuild-$mod",
  "private": true,
  "version": "0.0.0",
  "dependencies": {
    "$mod": "$version"
  }
}
EOF

  log "Installing fresh $mod@$version for Electron $ELECTRON_VERSION"
  (
    cd "$build_root"
    npm_config_runtime=electron \
    npm_config_target="$ELECTRON_VERSION" \
    npm_config_disturl=https://electronjs.org/headers \
    npm_config_arch="$ARCH" \
    npm_config_build_from_source=true \
    npm install --no-package-lock
  )
}

replace_module_in_targets() {
  local mod="$1"
  local source_dir="$2"
  local replaced=0

  for base in "$APP_UNPACKED_SRC" "$APP_SRC"; do
    local target="$base/node_modules/$mod"
    if [[ -d "$target" ]]; then
      rm -rf "$target"
      mkdir -p "$(dirname "$target")"
      cp -a "$source_dir" "$target"
      log "Replaced $mod in $target"
      replaced=1
    fi
  done

  if [[ "$replaced" -eq 0 ]]; then
    local target="$APP_UNPACKED_SRC/node_modules/$mod"
    mkdir -p "$(dirname "$target")"
    cp -a "$source_dir" "$target"
    log "Placed rebuilt $mod in $target"
  fi
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    return 1
  fi
}

norm_version() {
  local v="$1"
  if [[ "$v" =~ ^[0-9]+$ ]]; then
    echo "${v}.0.0"
  elif [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]]; then
    echo "${v}.0"
  else
    echo "$v"
  fi
}

DMG_PATH=""
ELECTRON_VERSION="40"
ARCH="x64"
OUT_DIR="./dist"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dmg)
      DMG_PATH="${2:-}"
      shift 2
      ;;
    --electron-version)
      ELECTRON_VERSION="${2:-}"
      shift 2
      ;;
    --arch)
      ARCH="${2:-}"
      shift 2
      ;;
    --out)
      OUT_DIR="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$DMG_PATH" ]]; then
  echo "--dmg is required" >&2
  usage
  exit 1
fi

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

ELECTRON_VERSION="$(norm_version "$ELECTRON_VERSION")"

need_cmd 7z
need_cmd node
need_cmd npx
need_cmd curl
need_cmd unzip

WORK_DIR="$(mktemp -d /tmp/repack-dmg.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

DMG_EXTRACT="$WORK_DIR/dmg"
APP_SRC="$WORK_DIR/app-src"
APP_UNPACKED_SRC="$WORK_DIR/app.asar.unpacked"
ASAR_REPACKED="$WORK_DIR/app-linux.asar"
ELECTRON_ZIP="$WORK_DIR/electron.zip"
ELECTRON_DIR="$WORK_DIR/electron"

mkdir -p "$DMG_EXTRACT" "$APP_SRC" "$APP_UNPACKED_SRC" "$ELECTRON_DIR" "$OUT_DIR"

log "Extracting DMG: $DMG_PATH"
# Some DMGs contain an /Applications symlink that 7z flags as a dangerous link path.
# Continue extraction and validate by checking for the .app bundle afterward.
7z x "$DMG_PATH" -o"$DMG_EXTRACT" >/dev/null || true

# DMG images commonly contain one or more HFS blobs; extract them if present.
while IFS= read -r -d '' hfs_file; do
  log "Extracting embedded image: $(basename "$hfs_file")"
  7z x "$hfs_file" -o"$DMG_EXTRACT" >/dev/null || true
done < <(find "$DMG_EXTRACT" -type f \( -name '*.hfs' -o -name '*.hfsx' -o -name '*.img' \) -print0)

APP_BUNDLE="$(find "$DMG_EXTRACT" -type d -name '*.app' | head -n1 || true)"
if [[ -z "$APP_BUNDLE" ]]; then
  echo "Could not locate a .app bundle after DMG extraction" >&2
  exit 1
fi
log "Found app bundle: $APP_BUNDLE"

ASAR_PATH="$(find "$APP_BUNDLE/Contents/Resources" -type f -name 'app.asar' | head -n1 || true)"
if [[ -z "$ASAR_PATH" ]]; then
  echo "Could not locate app.asar in $APP_BUNDLE/Contents/Resources" >&2
  exit 1
fi
log "Found asar: $ASAR_PATH"

log "Extracting app.asar"
npx --yes @electron/asar extract "$ASAR_PATH" "$APP_SRC"

ASAR_UNPACKED_PATH="$APP_BUNDLE/Contents/Resources/app.asar.unpacked"
if [[ -d "$ASAR_UNPACKED_PATH" ]]; then
  log "Copying app.asar.unpacked"
  cp -a "$ASAR_UNPACKED_PATH"/. "$APP_UNPACKED_SRC"/
fi

if [[ ! -f "$APP_SRC/package.json" ]]; then
  echo "package.json not found in extracted asar. Cannot rebuild native modules." >&2
  exit 1
fi

log "Removing macOS Sparkle artifacts (if present)"
find "$APP_SRC" -type d -iname '*sparkle*' -prune -exec rm -rf {} + || true
node - <<'NODE' "$APP_SRC/package.json"
const fs = require('fs');
const file = process.argv[2];
const pkg = JSON.parse(fs.readFileSync(file, 'utf8'));
const fields = ['dependencies', 'optionalDependencies', 'devDependencies'];
for (const field of fields) {
  if (!pkg[field]) continue;
  for (const name of Object.keys(pkg[field])) {
    if (/sparkle/i.test(name)) delete pkg[field][name];
  }
}
fs.writeFileSync(file, JSON.stringify(pkg, null, 2) + '\n');
NODE

log "Skipping dependency install; using packaged app node_modules"

rebuild_native_module() {
  local mod="$1"
  local found=0
  local rebuilt=0
  local mod_version=""

  # Prefer unpacked modules first, then packed asar source tree.
  for base in "$APP_UNPACKED_SRC" "$APP_SRC"; do
    local mod_dir="$base/node_modules/$mod"
    [[ -d "$mod_dir" ]] || continue
    found=1

    if [[ ! -f "$mod_dir/binding.gyp" ]]; then
      log "No binding.gyp for $mod at $mod_dir, skipping"
      continue
    fi

    log "Rebuilding native module: $mod in $mod_dir for Electron $ELECTRON_VERSION"
    if (
      cd "$mod_dir"
      npm_config_runtime=electron \
      npm_config_target="$ELECTRON_VERSION" \
      npm_config_disturl=https://electronjs.org/headers \
      npm_config_arch="$ARCH" \
      npm_config_build_from_source=true \
      npm rebuild
    ); then
      rebuilt=1
      break
    else
      warn "Rebuild failed for $mod at $mod_dir"
    fi
  done

  if [[ "$found" -eq 0 ]]; then
    log "Module not found, skipping rebuild: $mod"
  elif [[ "$rebuilt" -eq 0 ]]; then
    mod_version="$(get_module_version "$mod" || true)"
    if [[ -z "$mod_version" ]]; then
      warn "Could not determine $mod version for fallback install; app may not run on Linux"
      return 0
    fi

    if install_fresh_module "$mod" "$mod_version"; then
      replace_module_in_targets "$mod" "$WORK_DIR/native-mod-build/$mod/node_modules/$mod"
    else
      warn "Fallback fresh install failed for $mod@$mod_version; app may not run on Linux"
    fi
  fi
}

for mod in node-pty better-sqlite3; do
  rebuild_native_module "$mod"
done

log "Repacking Linux asar"
npx --yes @electron/asar pack "$APP_SRC" "$ASAR_REPACKED"

ELECTRON_TAG="v${ELECTRON_VERSION}"
ELECTRON_FILE="electron-v${ELECTRON_VERSION}-linux-${ARCH}.zip"
ELECTRON_URL="https://github.com/electron/electron/releases/download/${ELECTRON_TAG}/${ELECTRON_FILE}"

log "Downloading Electron runtime: $ELECTRON_URL"
curl -fL "$ELECTRON_URL" -o "$ELECTRON_ZIP"

log "Extracting Electron runtime"
unzip -q "$ELECTRON_ZIP" -d "$ELECTRON_DIR"

if [[ ! -d "$ELECTRON_DIR/resources" ]]; then
  echo "Electron runtime missing resources directory" >&2
  exit 1
fi

cp "$ASAR_REPACKED" "$ELECTRON_DIR/resources/app.asar"
if [[ -d "$APP_UNPACKED_SRC" ]] && [[ -n "$(ls -A "$APP_UNPACKED_SRC" 2>/dev/null)" ]]; then
  mkdir -p "$ELECTRON_DIR/resources/app.asar.unpacked"
  cp -a "$APP_UNPACKED_SRC"/. "$ELECTRON_DIR/resources/app.asar.unpacked"/
fi

if [[ -d "$APP_SRC/webview" ]]; then
  mkdir -p "$ELECTRON_DIR/content/webview"
  cp -a "$APP_SRC/webview"/. "$ELECTRON_DIR/content/webview"/
  log "Copied webview assets to content/webview"
else
  warn "webview directory not found in app.asar extraction"
fi

cat > "$ELECTRON_DIR/run-app.sh" <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBVIEW_DIR="$SCRIPT_DIR/content/webview"

pkill -f "codex-webview-server.js" 2>/dev/null || true
sleep 0.3

HTTP_PID=""
if [[ -d "$WEBVIEW_DIR" ]] && [[ -n "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]]; then
  cat > "$SCRIPT_DIR/codex-webview-server.js" <<'NODE'
const http = require("http");
const fs = require("fs");
const path = require("path");
const root = process.argv[2];
const port = Number(process.argv[3] || 5175);

const mime = {
  ".html": "text/html; charset=utf-8",
  ".js": "application/javascript; charset=utf-8",
  ".mjs": "application/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf"
};

function safeJoin(base, targetPath) {
  const target = "." + decodeURIComponent(targetPath.split("?")[0]);
  const resolved = path.resolve(base, target);
  if (!resolved.startsWith(path.resolve(base))) return null;
  return resolved;
}

const server = http.createServer((req, res) => {
  const reqPath = req.url === "/" ? "/index.html" : req.url;
  const full = safeJoin(root, reqPath);
  if (!full) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  fs.stat(full, (err, stat) => {
    if (err) {
      res.writeHead(404);
      res.end("Not Found");
      return;
    }

    let filePath = full;
    if (stat.isDirectory()) filePath = path.join(full, "index.html");

    fs.readFile(filePath, (readErr, data) => {
      if (readErr) {
        res.writeHead(404);
        res.end("Not Found");
        return;
      }
      const ext = path.extname(filePath).toLowerCase();
      res.setHeader("Content-Type", mime[ext] || "application/octet-stream");
      res.writeHead(200);
      res.end(data);
    });
  });
});

server.listen(port, "127.0.0.1");
NODE
  node "$SCRIPT_DIR/codex-webview-server.js" "$WEBVIEW_DIR" 5175 >/dev/null 2>&1 &
  HTTP_PID="$!"
fi

cleanup() {
  if [[ -n "$HTTP_PID" ]]; then
    kill "$HTTP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [[ -z "${CODEX_CLI_PATH:-}" ]]; then
  if command -v codex >/dev/null 2>&1; then
    export CODEX_CLI_PATH="$(command -v codex)"
  fi
fi

exec "$SCRIPT_DIR/electron" --no-sandbox "$@"
LAUNCH
chmod +x "$ELECTRON_DIR/run-app.sh"

FINAL_DIR="$OUT_DIR/$(basename "$APP_BUNDLE" .app)-linux"
rm -rf "$FINAL_DIR"
mkdir -p "$FINAL_DIR"
cp -a "$ELECTRON_DIR"/. "$FINAL_DIR"/

log "Done"
log "Linux package created at: $FINAL_DIR"
log "Launch with: $FINAL_DIR/run-app.sh"
