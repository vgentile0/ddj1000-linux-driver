#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
udev_rule_source="$repo_root/config/udev/99-ddj1000-hid.rules"
udev_rule_target="/etc/udev/rules.d/99-ddj1000-hid.rules"
hid_device_path="${DDJ1000_HID_DEVICE:-}"

packages=(
    pkgconf
    alsa-utils
    libasound2-dev
    libusb-1.0-0-dev
    libudev-dev
    libx11-dev
    libxext-dev
    libxrandr-dev
    libxcursor-dev
    libxi-dev
    libxfixes-dev
    libxss-dev
    libwayland-dev
    wayland-protocols
    libxkbcommon-dev
    libegl1-mesa-dev
    libgl1-mesa-dev
    pulseaudio-utils
    xinput
    x11-xserver-utils
)

usage() {
    cat <<'EOF'
Usage: ./scripts/setup-linux.sh <command>

Commands:
    check             Show Linux setup status for packages, udev rule, user groups, DDJ HID access, and DDJ USB access.
  install-packages  Install current Linux build dependencies via apt.
    install-udev      Install the DDJ-1000 hidraw plus USB udev rules and reload udev.
        install-host-stack-packages  Install additional host-stack desktop dependencies such as pactl.
  all               Run install-packages, install-udev, then check.
  help              Show this help.

Environment:
    DDJ1000_HID_DEVICE Override the hidraw device path to check. Default: auto-detect by USB ID 2b73:0020

Examples:
  ./scripts/setup-linux.sh check
  ./scripts/setup-linux.sh install-udev
  ./scripts/setup-linux.sh all
EOF
}

have_command() {
    command -v "$1" >/dev/null 2>&1
}

run_privileged() {
    if [[ "${EUID}" -eq 0 ]]; then
        "$@"
        return
    fi

    if have_command sudo; then
        sudo "$@"
        return
    fi

    echo "[ERROR] Root-Rechte noetig, aber sudo ist nicht verfuegbar: $*" >&2
    exit 1
}

print_status() {
    local label="$1"
    local state="$2"
    printf '%-24s %s\n' "$label" "$state"
}

check_packages() {
    local missing=0

    if ! have_command dpkg-query; then
        print_status "Pakete" "dpkg-query fehlt, Paketpruefung uebersprungen"
        return
    fi

    for package in "${packages[@]}"; do
        if dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q "install ok installed"; then
            :
        else
            if [[ "$missing" -eq 0 ]]; then
                echo "Fehlende Pakete:"
            fi
            echo "  - $package"
            missing=1
        fi
    done

    if [[ "$missing" -eq 0 ]]; then
        print_status "Pakete" "ok"
    else
        print_status "Pakete" "unvollstaendig"
    fi
}

install_packages() {
    if ! have_command apt-get; then
        echo "[ERROR] apt-get ist nicht verfuegbar. Paketinstallation wird nur fuer Debian/Ubuntu-Flow unterstuetzt." >&2
        exit 1
    fi

    run_privileged apt-get update
    run_privileged apt-get install -y "${packages[@]}"
}

install_host_stack_packages() {
    if ! have_command apt-get; then
        echo "[ERROR] apt-get ist nicht verfuegbar. Paketinstallation wird nur fuer Debian/Ubuntu-Flow unterstuetzt." >&2
        exit 1
    fi

    run_privileged apt-get update
    run_privileged apt-get install -y alsa-utils pulseaudio-utils
}

install_udev_rule() {
    if [[ ! -f "$udev_rule_source" ]]; then
        echo "[ERROR] Udev-Regel fehlt im Repo: $udev_rule_source" >&2
        exit 1
    fi

    run_privileged install -D -m 0644 "$udev_rule_source" "$udev_rule_target"
    run_privileged udevadm control --reload-rules
    run_privileged udevadm trigger

    echo
    echo "Die DDJ-1000-HID-Regel ist installiert."
    echo "Wenn der Controller bereits angeschlossen ist: einmal abziehen und wieder anstecken."
    echo
}

check_udev_rule() {
    if [[ -f "$udev_rule_target" ]]; then
        print_status "Udev-Regel" "installiert"
    else
        print_status "Udev-Regel" "fehlt ($udev_rule_target)"
    fi
}

check_groups() {
    local group_state="plugdev fehlt"
    local membership_state="nicht in plugdev"

    if getent group plugdev >/dev/null 2>&1; then
        group_state="vorhanden"
        if id -nG "$USER" | tr ' ' '\n' | grep -qx 'plugdev'; then
            membership_state="ok"
        else
            membership_state="fehlt"
        fi
    fi

    print_status "Gruppe plugdev" "$group_state"
    print_status "Benutzer in plugdev" "$membership_state"
}

resolve_hid_device() {
    if [[ -n "$hid_device_path" && -e "$hid_device_path" ]]; then
        printf '%s\n' "$hid_device_path"
        return
    fi

    local candidate
    for candidate in /sys/class/hidraw/hidraw*; do
        [[ -e "$candidate/device/uevent" ]] || continue
        if grep -q '^HID_ID=0003:00002B73:00000020$' "$candidate/device/uevent" 2>/dev/null; then
            printf '/dev/%s\n' "$(basename "$candidate")"
            return
        fi
    done

    printf "%s\n" "${hid_device_path:-not found}"
}

resolve_usb_device() {
    local candidate
    for candidate in /sys/bus/usb/devices/*; do
        [[ -f "$candidate/idVendor" && -f "$candidate/idProduct" ]] || continue
        if [[ "$(cat "$candidate/idVendor")" != "2b73" || "$(cat "$candidate/idProduct")" != "0020" ]]; then
            continue
        fi

        [[ -f "$candidate/busnum" && -f "$candidate/devnum" ]] || continue
        local busnum
        local devnum
        busnum="$(cat "$candidate/busnum")"
        devnum="$(cat "$candidate/devnum")"
        printf '/dev/bus/usb/%03d/%03d\n' "$busnum" "$devnum"
        return
    done
}

check_hid_access() {
    local device
    device="$(resolve_hid_device)"

    if [[ ! -e "$device" ]]; then
        print_status "DDJ HID Device" "nicht gefunden ($device)"
        return
    fi

    print_status "DDJ HID Device" "$device"
    print_status "Device Rechte" "$(stat -c '%A %U:%G' "$device")"

    if [[ -r "$device" && -w "$device" ]]; then
        print_status "HID Zugriff" "ok"
    else
        print_status "HID Zugriff" "kein Lese/Schreibzugriff"
    fi
}

check_usb_access() {
    local device
    device="$(resolve_usb_device || true)"

    if [[ -z "$device" ]]; then
        print_status "DDJ USB Device" "nicht gefunden"
        return
    fi

    print_status "DDJ USB Device" "$device"
    print_status "USB Rechte" "$(stat -c '%A %U:%G' "$device")"

    if [[ -r "$device" && -w "$device" ]]; then
        print_status "USB Zugriff" "ok"
    else
        print_status "USB Zugriff" "kein Lese/Schreibzugriff"
    fi
}

run_check() {
    echo "DDJ1000 Linux Setup Check"
    echo "Repo: $repo_root"
    echo
    check_packages
    check_udev_rule
    check_groups
    check_hid_access
    check_usb_access
}

main() {
    local command="${1:-help}"

    case "$command" in
        check)
            run_check
            ;;
        install-packages)
            install_packages
            ;;
        install-udev)
            install_udev_rule
            run_check
            ;;
        install-host-stack-packages)
            install_host_stack_packages
            run_check
            ;;
        all)
            install_packages
            install_udev_rule
            run_check
            ;;
        help|-h|--help)
            usage
            ;;
        *)
            echo "[ERROR] Unbekannter Befehl: $command" >&2
            echo >&2
            usage >&2
            exit 1
            ;;
    esac
}

main "$@"