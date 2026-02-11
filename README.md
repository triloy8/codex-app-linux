# Codex DMG to Linux Repack

This repository contains a helper script that repacks the macOS Codex Desktop `.dmg` into a Linux-runnable Electron bundle.

Inspired by: [ilysenko/codex-desktop-linux](https://github.com/ilysenko/codex-desktop-linux)

## Disclaimer

This project is **not affiliated with, endorsed by, or supported by OpenAI** in any way.
Use this script and any generated binaries **at your own risk**.

## What This Does

The script (`./codex-app-linux/repack-dmg-for-linux.sh`) automates:

1. Extracting a macOS `.dmg` with `7z`.
2. Locating the `.app` bundle and `app.asar`.
3. Extracting `app.asar` and optional `app.asar.unpacked`.
4. Removing Sparkle/macOS-updater related artifacts.
5. Rebuilding native modules (`node-pty`, `better-sqlite3`) for Linux + Electron.
6. Repacking `app.asar`.
7. Downloading Linux Electron runtime (matching requested version).
8. Copying web assets (`webview`) into `content/webview`.
9. Creating a launcher that:
   - starts a local Node static server on `127.0.0.1:5175`,
   - exports `CODEX_CLI_PATH` if `codex` is on PATH,
   - launches Electron with `--no-sandbox`.

Output is written under `dist/<AppName>-linux`.

## Requirements

Install these tools first:

- `7z`
- `node`
- `npm`
- `npx`
- `curl`
- `unzip`
- C/C++ build tooling (`make`, `g++`)

Typical Ubuntu/Debian:

```bash
sudo apt update
sudo apt install -y p7zip-full curl unzip build-essential
```

Install a recent Node.js (20+) via your preferred method.

## Usage

### Basic

```bash
./repack-dmg-for-linux.sh --dmg Codex.dmg --electron-version 40 --out ./dist
```

### With explicit semver + arch

```bash
./repack-dmg-for-linux.sh --dmg /absolute/path/Codex.dmg --electron-version 40.0.0 --arch x64 --out ./dist
```

Then launch:

```bash
./dist/Codex-linux/run-app.sh
```

## Notes and Caveats

- This is an unofficial repack workflow, not an official Linux distribution from OpenAI.
- Some macOS-specific internals may not map perfectly to Linux.
- Native rebuilds depend on network access (for npm packages and Electron build tooling).
- `7z` may print a symlink warning for `/Applications` while extracting DMGs; the script tolerates this.

## Troubleshooting

- If UI does not appear, run with logs:
  ```bash
  ./dist/Codex-linux/run-app.sh --enable-logging --v=1
  ```
- If `npm` rebuild fails, verify build tools are installed and retry.
- If `codex` is not found at runtime, install CLI and/or set:
  ```bash
  export CODEX_CLI_PATH="$(command -v codex)"
  ```

## Repository Contents

- `./codex-app-linux/repack-dmg-for-linux.sh` — main repack script
- `./codex-app-linux/Codex.dmg` — source DMG (local)
- `./codex-app-linux/dist/` — generated Linux bundle(s)
