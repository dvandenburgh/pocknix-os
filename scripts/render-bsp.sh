#!/usr/bin/env bash
# render-bsp.sh <boards dir> <out dir>: the family BSP files the build renders, not commits.
#   device.conf  the dispatcher: picks boards/<board>.conf by devicetree model (boards/models)
#   family.conf  boards/family.conf plus the install-to-internal keys the profile owns
# Takes the profile's BOOTLOADER, SD_FAT_LABEL and ROOT_LABEL from the environment.
set -euo pipefail
boards="$1" out="$2"
: "${BOOTLOADER:?}" "${SD_FAT_LABEL:?}" "${ROOT_LABEL:?}"
mkdir -p "${out}"

# Consumers source device.conf (some under set -e, cores.sh inside $(...)), so it stays POSIX sh,
# prints nothing and always returns 0.
awk -v q="'" '
  /^[[:space:]]*(#|$)/ { next }
  {
    b = $1; m = $0
    sub(/^[[:space:]]*[^[:space:]]+[[:space:]]+/, "", m); sub(/[[:space:]]+$/, "", m)
    if (fb == "") fb = b
    arms = arms "  \"" m "\")\n    . /usr/lib/pocknix/boards/" b ".conf\n    ;;\n"
  }
  END {
    print "# /usr/lib/pocknix/device.conf, generated from the BSP" q "s boards/models: picks the board"
    print "# file by devicetree model. An unknown or absent model (the image-build chroot) gets"
    print "# the first board and POCKNIX_BOARD_UNKNOWN=1. /etc/pocknix/device.conf overrides."
    print "_pocknix_model=\"$(cat /proc/device-tree/model 2>/dev/null | tr -d " q "\\0" q ")\""
    print "case \"${_pocknix_model}\" in"
    printf "%s", arms
    print "  *)"
    print "    POCKNIX_BOARD_UNKNOWN=1"
    print "    . /usr/lib/pocknix/boards/" fb ".conf"
    print "    [ -n \"${_pocknix_model}\" ] && \\"
    print "      logger -t pocknix \"device.conf: unknown DT model " q "${_pocknix_model}" q " - using " fb " board defaults\" 2>/dev/null || true"
    print "    ;;"
    print "esac"
    print "unset _pocknix_model"
  }' "${boards}/models" > "${out}/device.conf"

# An internal install copies the SD's boot style and labels.
{ awk 1 "${boards}/family.conf"
  printf 'POCKNIX_BOOT_STYLE=%s\nPOCKNIX_BOOT_FAT_LABEL=%s\nPOCKNIX_ROOT_LABEL=%s\n' \
    "${BOOTLOADER}" "${SD_FAT_LABEL}" "${ROOT_LABEL}"
} > "${out}/family.conf"
