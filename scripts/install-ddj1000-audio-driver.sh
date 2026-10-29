#!/usr/bin/env bash
#
# Install the DDJ-1000 snd-usb-audio override as a DKMS package.
# DKMS rebuilds and re-signs the modules automatically for every new kernel.
#
# Target: Debian 13 / MX Linux 25 (kernel series 6.12). Other series need a
# matching snd-usb-audio-ddj1000-<series>.patch in the patch directory.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"

dkms_name="ddj1000-snd-usb-audio"
dkms_version="$(sed -n 's/^PACKAGE_VERSION="\(.*\)"/\1/p' "$repo_root/dkms/dkms.conf")"
dkms_src="/usr/src/$dkms_name-$dkms_version"

kernel_version="$(uname -r)"
kernel_series="$(cut -d. -f1,2 <<< "$kernel_version")"

# Location used by the original (non-DKMS) installer of this project.
legacy_dir="/lib/modules/$kernel_version/updates/ddj1000-linux-driver"

have_command() {
    command -v "$1" >/dev/null 2>&1
}

run_privileged() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
        return
    fi
    if have_command sudo; then
        sudo "$@"
        return
    fi
    echo "[ERROR] Root rights required, but sudo is unavailable: $*" >&2
    exit 1
}

required_packages() {
    printf '%s\n' dkms build-essential patch xz-utils \
        "linux-headers-$kernel_version" "linux-source-$kernel_series"
}

missing_packages() {
    local pkg
    while read -r pkg; do
        dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -Eq "(install|hold) ok installed" || echo "$pkg"
    done < <(required_packages)
}

install_dependencies() {
    local missing
    missing="$(missing_packages)"
    if [[ -z "$missing" ]]; then
        echo "[INFO] Build dependencies already installed."
        return
    fi
    echo "[INFO] Installing: $(tr '\n' ' ' <<< "$missing")"
    echo "[INFO] (this step needs Internet)"
    run_privileged apt-get update
    # shellcheck disable=SC2086
    run_privileged apt-get install -y $missing
}

check_patch_available() {
    local patch="$repo_root/patches/linux/snd-usb-audio-ddj1000-$kernel_series.patch"
    if [[ ! -f "$patch" ]]; then
        echo "[ERROR] No DDJ-1000 patch for kernel series $kernel_series." >&2
        local f
        printf '        Available:' >&2
        for f in "$repo_root"/patches/linux/snd-usb-audio-ddj1000-*.patch; do
            printf ' %s' "$(basename "$f")" >&2
        done
        echo >&2
        exit 1
    fi
}

remove_legacy_modules() {
    if [[ -d "$legacy_dir" ]]; then
        echo "[INFO] Removing modules from the old manual installer: $legacy_dir"
        run_privileged rm -rf "$legacy_dir"
    fi
}

stage_dkms_source() {
    local tmp
    tmp="$(mktemp -d)"
    install -d "$tmp/patches"
    install -m 0644 "$repo_root/dkms/dkms.conf" "$tmp/dkms.conf"
    install -m 0644 "$repo_root/dkms/Makefile" "$tmp/Makefile"
    install -m 0755 "$repo_root/dkms/prepare-sources.sh" "$tmp/prepare-sources.sh"
    install -m 0644 "$repo_root"/patches/linux/snd-usb-audio-ddj1000-*.patch "$tmp/patches/"

    run_privileged rm -rf "$dkms_src"
    run_privileged cp -r "$tmp" "$dkms_src"
    run_privileged chown -R root:root "$dkms_src"
    rm -rf "$tmp"
}

remove_dkms_package() {
    local dir version
    for dir in /var/lib/dkms/"$dkms_name"/*/; do
        [[ -d "$dir" ]] || continue
        version="$(basename "$dir")"
        [[ "$version" == "source" || "$version" == kernel-* ]] && continue
        run_privileged dkms remove -m "$dkms_name" -v "$version" --all || true
    done
    run_privileged rm -rf /var/lib/dkms/"$dkms_name" /usr/src/"$dkms_name"-*
}

reload_modules() {
    run_privileged modprobe -r snd_usb_audio snd_usbmidi_lib 2>/dev/null || true
    run_privileged modprobe snd_usb_audio
}

# The file on disk can be the patched one while the kernel still runs the
# stock module (unload fails when PipeWire or another USB sound card holds it).
loaded_module_is_patched() {
    local on_disk loaded
    on_disk="$(modinfo -F srcversion snd_usb_audio 2>/dev/null || true)"
    loaded="$(cat /sys/module/snd_usb_audio/srcversion 2>/dev/null || true)"
    [[ -n "$on_disk" && "$on_disk" == "$loaded" ]]
}

show_loaded_state() {
    if [[ ! -d /sys/module/snd_usb_audio ]]; then
        printf '%-22s %s\n' "Loaded module" "not loaded"
    elif loaded_module_is_patched; then
        printf '%-22s %s\n' "Loaded module" "patched (running)"
    else
        printf '%-22s %s\n' "Loaded module" "STOCK still in memory -> reboot"
    fi
}

show_secure_boot_hint() {
    if have_command mokutil && mokutil --sb-state 2>/dev/null | grep -qi 'enabled'; then
        echo
        echo "[WARN] Secure Boot is enabled. DKMS signed the modules with its own key."
        echo "       Enroll it once, then reboot and choose 'Enroll MOK':"
        echo "         sudo mokutil --import /var/lib/dkms/mok.pub"
        echo "       (Simpler alternative: disable Secure Boot in the BIOS.)"
    fi
}

install_driver() {
    check_patch_available
    install_dependencies
    remove_legacy_modules
    remove_dkms_package
    stage_dkms_source

    run_privileged dkms add -m "$dkms_name" -v "$dkms_version"
    # Some dkms wrappers also try every other installed kernel; builds for
    # kernels without headers fail and are harmless. What matters is the
    # running kernel.
    run_privileged dkms install -m "$dkms_name" -v "$dkms_version" -k "$kernel_version" || true
    if ! dkms status -m "$dkms_name" -v "$dkms_version" -k "$kernel_version" 2>/dev/null | grep -q 'installed'; then
        echo "[ERROR] DKMS build failed for $kernel_version. Show the log with:" >&2
        echo "        sudo tail -40 /var/lib/dkms/$dkms_name/$dkms_version/build/make.log" >&2
        exit 1
    fi
    echo "[INFO] DKMS module installed for $kernel_version."

    reload_modules || true

    echo
    echo "Active snd_usb_audio module:"
    modinfo -n snd_usb_audio || true
    if [[ -d /sys/module/snd_usb_audio ]] && ! loaded_module_is_patched; then
        echo
        echo "[WARN] The stock snd_usb_audio is still loaded in memory (in use by"
        echo "       PipeWire or another USB sound card). Reboot to activate the"
        echo "       patched module: sudo reboot"
    fi
    show_secure_boot_hint
    echo
    echo "Playback devices:"
    aplay -l || true
}

uninstall_driver() {
    remove_dkms_package
    remove_legacy_modules
    run_privileged depmod -a "$kernel_version"
    reload_modules || true
    echo
    echo "DDJ-1000 DKMS package removed. Active snd_usb_audio:"
    modinfo -n snd_usb_audio || true
}

status() {
    local active_path
    active_path="$(modinfo -n snd_usb_audio 2>/dev/null || true)"

    echo "DDJ-1000 audio-driver status"
    echo
    printf '%-22s %s\n' "Kernel" "$kernel_version"
    printf '%-22s %s\n' "Patch for series" "$( [[ -f "$repo_root/patches/linux/snd-usb-audio-ddj1000-$kernel_series.patch" ]] && echo "$kernel_series: present" || echo "$kernel_series: MISSING" )"
    printf '%-22s %s\n' "Missing packages" "$(missing_packages | tr '\n' ' ')"
    printf '%-22s %s\n' "DKMS" "$(dkms status -m "$dkms_name" 2>/dev/null | tr '\n' ' ' || echo 'dkms not installed')"
    printf '%-22s %s\n' "Active snd_usb_audio" "${active_path:-unknown}"
    show_loaded_state
    if [[ "$active_path" == */updates/dkms/* ]]; then
        printf '%-22s %s\n' "Result" "patched module active"
    else
        printf '%-22s %s\n' "Result" "stock module active (no DDJ-1000 audio)"
    fi
}

usage() {
    cat <<'EOF'
Usage: ./scripts/install-ddj1000-audio-driver.sh <command>

Commands:
  install     Install build dependencies (needs Internet the first time),
              register the DKMS package, build, install and reload snd_usb_audio.
  uninstall   Remove the DKMS package and return to the stock module.
  status      Show kernel, patch, DKMS and active-module state.
  deps        Only install the build dependencies (do this while online).
  help        Show this help.

Notes:
  - Modules go to /lib/modules/<kernel>/updates/dkms and are rebuilt
    automatically by DKMS on kernel upgrades.
  - Requires Debian's linux-source-X.Y package for the running kernel series.
EOF
}

main() {
    case "${1:-help}" in
        install)   install_driver ;;
        uninstall) uninstall_driver ;;
        status)    status ;;
        deps)      install_dependencies ;;
        help|-h|--help) usage ;;
        *)
            echo "Unknown command: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
}

main "$@"
