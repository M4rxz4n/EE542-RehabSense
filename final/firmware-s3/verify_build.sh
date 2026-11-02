#!/usr/bin/env bash
# Compile rehabsense_s3 for both ESP32-S3 boards, from nothing, with no IDE.
#
# Why this exists
# ---------------
# The prototype firmware was only ever checked by compiling its modules on a
# laptop against hand-written stubs, because no ESP32 toolchain was available
# where that work happened. Stubs cannot catch what actually breaks on a board
# change: whether analogSetPinAttenuation still takes that enum on an S3,
# whether SPI.begin has the four-argument form, whether the sketch fits the
# partition. This builds the real thing with the real toolchain instead, and
# prints the flash and RAM it costs.
#
# It installs its own toolchain under ./.build-tools and touches nothing else -
# not ~/.arduino15, not an installed IDE. Delete that directory to start over.
# About 500 MB downloaded, a few minutes the first time, seconds after that.
#
# Usage:  ./verify_build.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKETCH="$HERE/rehabsense_s3"
TOOLS="$HERE/.build-tools"
CLI_VER=1.1.1
CORE_VER=3.3.12
NIMBLE_TAG=2.5.2

export ARDUINO_DIRECTORIES_DATA="$TOOLS/data"
export ARDUINO_DIRECTORIES_USER="$TOOLS/user"
export ARDUINO_DIRECTORIES_DOWNLOADS="$TOOLS/dl"
CLI="$TOOLS/arduino-cli"
mkdir -p "$TOOLS" "$ARDUINO_DIRECTORIES_DATA" "$ARDUINO_DIRECTORIES_USER/libraries" "$ARDUINO_DIRECTORIES_DOWNLOADS"

say() { printf '\n== %s\n' "$*"; }

# ---- arduino-cli -------------------------------------------------------
if [ ! -x "$CLI" ]; then
  say "arduino-cli $CLI_VER"
  curl -fsSL "https://github.com/arduino/arduino-cli/releases/download/v${CLI_VER}/arduino-cli_${CLI_VER}_Linux_64bit.tar.gz" \
    | tar xz -C "$TOOLS" arduino-cli
fi

# ---- esp32 core, installed by hand ------------------------------------
#
# Not `arduino-cli core install`: that resolves every tool a board mentions,
# upload tools included, and pulls its index from downloads.arduino.cc. Here
# the archives come straight from the GitHub releases they are published in,
# and only the five an Xtensa S3 compile actually uses are fetched - the
# RISC-V toolchain alone is another 590 MB of nothing we need.
CORE_DIR="$ARDUINO_DIRECTORIES_DATA/packages/esp32/hardware/esp32/$CORE_VER"
if [ ! -d "$CORE_DIR" ]; then
  say "esp32 core $CORE_VER + Xtensa toolchain"
  P="$ARDUINO_DIRECTORIES_DATA/packages/esp32"
  mkdir -p "$P/hardware/esp32" "$P/tools" "$TOOLS/dl-manual"
  cd "$TOOLS/dl-manual"

  get() { [ -f "$2" ] || curl -fsSL --retry 3 -o "$2" "$1"; }
  get "https://github.com/espressif/arduino-esp32/releases/download/$CORE_VER/esp32-core-$CORE_VER.zip" core.zip
  get "https://github.com/espressif/crosstool-NG/releases/download/esp-14.2.0_20260121/xtensa-esp-elf-14.2.0_20260121-x86_64-linux-gnu.tar.gz" xtensa.tar.gz
  get "https://github.com/espressif/arduino-esp32/releases/download/$CORE_VER/esp32s3-libs-$CORE_VER.zip" s3libs.zip
  get "https://github.com/espressif/esptool/releases/download/v5.3.1/esptool-v5.3.1-linux-amd64.tar.gz" esptool.tar.gz
  get "https://github.com/earlephilhower/mklittlefs/releases/download/4.0.2/x86_64-linux-gnu-mklittlefs-db0513a.tar.gz" mklittlefs.tar.gz
  get "https://github.com/igrr/mkspiffs/releases/download/0.2.3/mkspiffs-0.2.3-arduino-esp32-linux64.tar.gz" mkspiffs.tar.gz

  unpack() { # archive, destination
    rm -rf _x && mkdir _x
    case "$1" in *.zip) (cd _x && unzip -q "../$1");; *) (cd _x && tar xzf "../$1");; esac
    mkdir -p "$(dirname "$2")"
    if [ "$(ls _x | wc -l)" = 1 ] && [ -d "_x/$(ls _x)" ]; then mv "_x/$(ls _x)" "$2"
    else mkdir -p "$2" && mv _x/* "$2"/; fi
    rm -rf _x
  }
  unpack core.zip        "$P/hardware/esp32/$CORE_VER"
  unpack xtensa.tar.gz   "$P/tools/esp-x32/2601"
  unpack s3libs.zip      "$P/tools/esp32s3-libs/$CORE_VER"
  unpack esptool.tar.gz  "$P/tools/esptool_py/5.3.1"
  unpack mklittlefs.tar.gz "$P/tools/mklittlefs/4.0.2-db0513a"
  unpack mkspiffs.tar.gz "$P/tools/mkspiffs/0.2.3"
  cd "$HERE"
fi

# Indexes arduino-cli insists on, and a stub for the one upload tool the S3
# boards name. dfu-util pushes a binary over USB; a compile never runs it.
[ -f "$ARDUINO_DIRECTORIES_DATA/library_index.json" ] || echo '{"libraries":[]}' > "$ARDUINO_DIRECTORIES_DATA/library_index.json"
if [ ! -f "$ARDUINO_DIRECTORIES_DATA/package_index.json" ]; then
  python3 - "$ARDUINO_DIRECTORIES_DATA" <<'PY'
import json, os, sys
data = sys.argv[1]
sysname = lambda h: {"host": h, "url": "file:///dev/null",
                     "archiveFileName": "stub.tar.gz",
                     "checksum": "SHA-256:" + "0" * 64, "size": "0"}
json.dump({"packages": [{"name": "arduino", "maintainer": "Arduino",
    "websiteURL": "", "email": "", "platforms": [],
    "tools": [{"name": "dfu-util", "version": "0.11.0-arduino5",
               "systems": [sysname("x86_64-pc-linux-gnu"), sysname("x86_64-linux-gnu")]}]}]},
    open(os.path.join(data, "package_index.json"), "w"))
d = os.path.join(data, "packages/arduino/tools/dfu-util/0.11.0-arduino5")
os.makedirs(d, exist_ok=True)
open(os.path.join(d, "README.stub"), "w").write("Upload-only tool. Not used by a compile.\n")
PY
fi

# arduino-ctags, which arduino-cli uses to synthesise function prototypes for
# a .ino, is published only on a host we cannot reach. The sketch defines every
# function before it is used, so no prototypes are needed; a no-op keeps the
# build honest, because a sketch that did need one fails to compile loudly.
CTAGS="$TOOLS/ctags-shim"
if [ ! -x "$CTAGS/ctags" ]; then
  mkdir -p "$CTAGS"
  printf '#!/bin/sh\nexit 0\n' > "$CTAGS/ctags"
  chmod +x "$CTAGS/ctags"
fi

# ---- libraries ---------------------------------------------------------
lib() { # repo, directory, optional tag
  local d="$ARDUINO_DIRECTORIES_USER/libraries/$2"
  [ -d "$d" ] || { say "library $2"; git clone --depth 1 -q "https://github.com/$1.git" "$d"; }
  if [ -n "${3:-}" ]; then
    git -C "$d" fetch --depth 1 -q origin "refs/tags/$3:refs/tags/$3" 2>/dev/null || true
    git -C "$d" -c advice.detachedHead=false checkout -q "$3" 2>/dev/null || true
  fi
}
lib sparkfun/SparkFun_BMI270_Arduino_Library SparkFun_BMI270_Arduino_Library
lib adafruit/Adafruit_DRV2605_Library        Adafruit_DRV2605_Library
lib adafruit/Adafruit_BusIO                  Adafruit_BusIO
lib h2zero/NimBLE-Arduino                    NimBLE-Arduino "$NIMBLE_TAG"

# ---- compile -----------------------------------------------------------
# Three configurations, because each answers a different question:
#   XIAO, PSRAM off   the shipping board as the IDE hands it to you
#   XIAO, PSRAM OPI   the shipping board set up as its hardware actually is
#   S3 Dev Module     the board the PRD names, to prove one build serves both
fail=0
for fqbn in "esp32:esp32:XIAO_ESP32S3" \
            "esp32:esp32:XIAO_ESP32S3:PSRAM=opi" \
            "esp32:esp32:esp32s3"; do
  say "compile $fqbn"
  if "$CLI" compile -b "$fqbn" --warnings all \
       --build-property "runtime.tools.ctags.path=$CTAGS" "$SKETCH" 2>&1 \
       | grep -v "^Error initializing" \
       | grep -iE "\berror\b|warning:|Sketch uses|Global variables"; then :; fi
  "$CLI" compile -b "$fqbn" --warnings all \
    --build-property "runtime.tools.ctags.path=$CTAGS" "$SKETCH" >/dev/null 2>&1 || { echo "FAILED: $fqbn"; fail=1; }
done

say "$([ $fail = 0 ] && echo "all three configurations build" || echo "something did not build")"
exit $fail
