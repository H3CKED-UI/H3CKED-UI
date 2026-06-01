#!/bin/bash
set -e

sudo apt update
sudo apt install -y \
  p7zip-full lz4 android-sdk-libsparse-utils \
  python3 python3-pip zipalign unzip default-jre openjdk-17-jdk brotli \
  e2fsprogs zstd aria2 whiptail

DEVICES_DIR="$PWD/H3CKED-UI/Devices"

if ! command -v whiptail >/dev/null 2>&1; then
    echo "[ERROR] whiptail not installed. Run: sudo apt install whiptail"
    exit 1
fi

git lfs update --force

DEVICE_LIST=()

for dir in "$DEVICES_DIR"/SM-*; do
    [ -d "$dir" ] || continue
    dev=$(basename "$dir")
    DEVICE_LIST+=("$dev" "")
done

if [ ${#DEVICE_LIST[@]} -eq 0 ]; then
    echo "[ERROR] No devices found in $DEVICES_DIR"
    exit 1
fi

STOCK_DEVICE=$(whiptail \
    --title "H3CKED-UI Builder" \
    --menu "Select Stock Device" \
    20 60 10 \
    "${DEVICE_LIST[@]}" \
    3>&1 1>&2 2>&3)

if [ -z "$STOCK_DEVICE" ]; then
    echo "[INFO] Cancelled"
    exit 1
fi

KERNEL_BPF_VERSION=$(whiptail \
    --title "Kernel BPF Version" \
    --menu "Select kernel BPF version" \
    15 60 2 \
    "5.4" "" \
    "5.10" "" \
    3>&1 1>&2 2>&3)

if [ -z "$KERNEL_BPF_VERSION" ]; then
    echo "[INFO] Cancelled"
    exit 1
fi

if [ "$KERNEL_BPF_VERSION" = "5.10" ]; then
    USE_UI_8_TETHERING_APEX="false"
else
    USE_UI_8_TETHERING_APEX="true"
fi

FW_URL=$(whiptail \
    --inputbox "Firmware URL (REQUIRED)" \
    10 70 \
    3>&1 1>&2 2>&3)

if [ -z "$FW_URL" ]; then
    echo "[ERROR] Firmware URL is required. Aborting build."
    exit 1
fi

H3CKED_UI_VERSION="1.2.0"
OUTPUT_FILESYSTEM="erofs"

OUT_DIR="$PWD/OUT"
WORK_DIR="$PWD/WORK"
FIRM_DIR="$PWD/FIRMWARE"
APKTOOL="$PWD/bin/apktool/apktool.jar"
VNDKS_COLLECTION="$PWD/H3CKED-UI/vndks"

BUILD_PARTITIONS="product,vendor,odm,system_ext,system"

export H3CKED_UI_BUILD="${H3CKED_UI_BUILD:-}"
export OFFICIAL_HASH="${OFFICIAL_HASH:-}"

source scripts/H3CKED-UI.sh
GITHUB_ENV=/dev/null
IS_OFFICIAL

git lfs install
git lfs pull

chmod +x bin/erofs-utils/extract.erofs
chmod +x bin/erofs-utils/mkfs.erofs

bash scripts/setup_directories.sh FIRMWARE WORK OUT

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

source scripts/H3CKED-UI.sh

DOWNLOAD_FIRMWARE "$STOCK_DEVICE" "$FIRM_DIR" "$FW_URL"

export TARGET_DEVICE

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

BUILD_IMG "FIRMWARE" "$OUTPUT_FILESYSTEM" "$OUT_DIR"
IMG_TO_BROTLI "$OUT_DIR" "TMP"

source scripts/zip_creation.sh
UPDATE_ZIP_SCRIPT "FIRMWARE"
FLASHABLE_ZIP_CREATION

if [ -f "./upload.sh" ]; then
    chmod +x ./upload.sh
    bash ./upload.sh "$(pwd)/template/${ZIP_NAME}"
fi

echo "Build finished. ROM located at: ${OUT_DIR}/${ZIP_NAME}"