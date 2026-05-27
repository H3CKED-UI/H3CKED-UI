#!/bin/bash
set -e

########################################
# USER INPUTS (replace like workflow_dispatch)
########################################

STOCK_DEVICE="${1:-SM-A226B}"
USE_UI_8_TETHERING_APEX="${2:-true}"
FW_URL="${3:-}"

H3CKED_UI_VERSION="1.2.0"
OUTPUT_FILESYSTEM="erofs"

########################################
# PATHS (same as GITHUB_ENV)
########################################

OUT_DIR="$PWD/OUT"
WORK_DIR="$PWD/WORK"
FIRM_DIR="$PWD/FIRMWARE"
DEVICES_DIR="$PWD/H3CKED-UI/Devices"
APKTOOL="$PWD/bin/apktool/apktool.jar"
VNDKS_COLLECTION="$PWD/H3CKED-UI/vndks"

BUILD_PARTITIONS="product,vendor,odm,system_ext,system"

########################################
# CHECK REPO (replaces secrets step)
########################################

export H3CKED_UI_BUILD="${H3CKED_UI_BUILD:-}"
export OFFICIAL_HASH="${OFFICIAL_HASH:-}"

source scripts/H3CKED-UI.sh
GITHUB_ENV=/dev/null
IS_OFFICIAL

########################################
# SETUP
########################################

git lfs install
git lfs pull

chmod +x bin/erofs-utils/extract.erofs
chmod +x bin/erofs-utils/mkfs.erofs

bash scripts/setup_directories.sh FIRMWARE WORK OUT

# Auto JVM memory tuning for ROM build
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))

if [ "$TOTAL_RAM_GB" -ge 24 ]; then
    export _JAVA_OPTIONS="-Xmx8G -XX:+UseG1GC"
elif [ "$TOTAL_RAM_GB" -ge 16 ]; then
    export _JAVA_OPTIONS="-Xmx6G -XX:+UseG1GC"
else
    export _JAVA_OPTIONS="-Xmx4G -XX:+UseG1GC"
fi

echo "[JAVA] Using heap: $_JAVA_OPTIONS"

########################################
# INSTALL DEPENDENCIES (CI equivalent)
########################################

sudo apt update
sudo apt install -y \
  p7zip-full lz4 android-sdk-libsparse-utils \
  python3 python3-pip zipalign unzip default-jre openjdk-17-jdk brotli \
  e2fsprogs zstd aria2

python3 -m pip install --break-system-packages liblp tgcrypto pyrogram gdown

# FW DL

if [ -d "FIRMWARE/.cache_valid" ] && [ -z "$FW_URL" ]; then
  echo "[INFO] Using cached firmware"
else
  if [ -n "$FW_URL" ]; then
    echo "[INFO] Downloading firmware from URL"
    source scripts/H3CKED-UI.sh
    DOWNLOAD_FIRMWARE "$STOCK_DEVICE" "$FIRM_DIR" "$FW_URL"
  else
    echo "[INFO] No FW_URL provided, using default device config"
    source "$DEVICES_DIR/$STOCK_DEVICE/config"
    source scripts/H3CKED-UI.sh
    DOWNLOAD_FIRMWARE "$TARGET_DEVICE" "$FIRM_DIR" ""
  fi

  touch FIRMWARE/.cache_valid
fi


# ROM BUILD


source scripts/H3CKED-UI.sh

EXTRACT_FIRMWARE "FIRMWARE"
PREPARE_PARTITIONS "FIRMWARE"
EXTRACT_FIRMWARE_IMG "FIRMWARE"

DISABLE_FBE "FIRMWARE"
DISABLE_FDE "FIRMWARE"
DELETE_ICCC "FIRMWARE"
DEBLOAT_VENDOR "FIRMWARE"
PATCH_FSTAB_EROFS "FIRMWARE"

APPLY_STOCK_CONFIG "FIRMWARE"
DEBLOAT "FIRMWARE"
APPLY_FEATURES "FIRMWARE"
APPLY_MODS "FIRMWARE"

APPENDING_DISPLAY_ID "FIRMWARE"

# PATCHES

INSTALL_FRAMEWORK "FIRMWARE/system/system/framework/framework-res.apk"

DECOMPILE "$APKTOOL" \
  "FIRMWARE/system/system/framework/ssrm.jar" "$WORK_DIR"

DECOMPILE "$APKTOOL" \
  "FIRMWARE/system/system/framework/services.jar" "$WORK_DIR"

source scripts/Knox_script.sh

PATCH_SSRM "$WORK_DIR/ssrm"
PATCH_KNOX_GUARD "$WORK_DIR/services"
PATCH_FLAG_SECURE "$WORK_DIR/services"
PATCH_SECURE_FOLDER "$WORK_DIR/services"
PATCH_PRIVATE_SHARE "$WORK_DIR/services"
DISABLE_SIGNATURE_VERIFICATION "$WORK_DIR/services"

RECOMPILE "$APKTOOL" "$WORK_DIR/ssrm" \
  "FIRMWARE/system/system/framework" "$WORK_DIR"

RECOMPILE "$APKTOOL" "$WORK_DIR/services" \
  "FIRMWARE/system/system/framework" "$WORK_DIR"

cp -fv "$WORK_DIR"/*.jar "FIRMWARE/system/system/framework/"

# BUILD IMG

BUILD_IMG "FIRMWARE" "$OUTPUT_FILESYSTEM" "$OUT_DIR"
IMG_TO_BROTLI "$OUT_DIR" "TMP"

# CREATE ZIP

source scripts/zip_creation.sh
UPDATE_ZIP_SCRIPT "FIRMWARE"
FLASHABLE_ZIP_CREATION

# UPLOAD ZIP

if [ -f "./upload.sh" ]; then
  chmod +x ./upload.sh
  bash ./upload.sh "$(pwd)/template/${ZIP_NAME}"
fi

echo "Build finished. ROM located at: ${OUT_DIR}/${ZIP_NAME}"