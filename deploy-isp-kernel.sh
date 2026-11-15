#!/usr/bin/env bash
# Install the built kernel on this Orange Pi 5 Plus, keeping the existing boot path.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo or pkexec' >&2; exit 1; }
isp_reboot=0
case ${1:-} in
    '') ;;
    --reboot) isp_reboot=1 ;;
    *) echo 'Usage: sudo ./deploy-isp-kernel.sh [--reboot]' >&2; exit 2 ;;
esac
[[ $# -le 1 ]] || exit 2
[[ $(uname -m) == aarch64 ]] || { echo 'Deploy only on the ARM64 development board' >&2; exit 1; }
[[ -r /proc/device-tree/compatible ]] || { echo 'No board device tree' >&2; exit 1; }
tr '\0' '\n' < /proc/device-tree/compatible | grep -qi 'orangepi.*5.plus' || { echo 'Expected Orange Pi 5 Plus' >&2; exit 1; }
isp_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$isp_root"
isp_output=$(realpath -m -- "${ISP_BUILD_DIR:-build-ov13855-testpattern}")
isp_release=6.1.43-rockchip-rk3588
[[ $(cat "$isp_output/include/config/kernel.release") == "$isp_release" ]] || { echo 'Kernel version mismatch' >&2; exit 1; }
[[ $(uname -r) == "$isp_release" ]] || { echo 'Running kernel version mismatch' >&2; exit 1; }
file "$isp_output/arch/arm64/boot/Image" | grep -q 'Linux kernel ARM64'
while IFS= read -r isp_module; do
    [[ -f "$isp_output/$isp_module" ]] || { echo "Missing module: $isp_module" >&2; exit 1; }
done < "$isp_output/modules.order"
exec 9>/run/lock/rk3588-isp-deploy.lock
flock -n 9 || { echo 'Another deployment is running' >&2; exit 1; }
mkdir -p /var/backups/rk3588-isp
isp_backup=$(mktemp -d /var/backups/rk3588-isp/rollback.XXXXXXXX)
mkdir -p "$isp_backup/boot" "$isp_backup/modules"
isp_names=(Image uInitrd "initrd.img-$isp_release" "vmlinuz-$isp_release" "System.map-$isp_release" "config-$isp_release")
: > "$isp_backup/boot-files.list"
: > "$isp_backup/boot-files-absent.list"
for isp_name in "${isp_names[@]}"; do
    if [[ -e "/boot/$isp_name" || -L "/boot/$isp_name" ]]; then
        cp -a -- "/boot/$isp_name" "$isp_backup/boot/$isp_name"
        printf '%s\n' "$isp_name" >> "$isp_backup/boot-files.list"
    else
        printf '%s\n' "$isp_name" >> "$isp_backup/boot-files-absent.list"
    fi
done
cp -a "/lib/modules/$isp_release" "$isp_backup/modules/"
install -m 0755 restore-isp-kernel.sh "$isp_backup/restore-isp-kernel.sh"
sha256sum /boot/Image /boot/uInitrd > "$isp_backup/original-boot.sha256"
touch "$isp_backup/backup-complete"
printf 'Backup: %s\n' "$isp_backup"
isp_changed=0
isp_stage=$(mktemp -d /var/tmp/rk3588-isp-deploy.XXXXXXXX)
isp_failed() {
    isp_rc=$?
    trap - ERR
    echo "Deployment failed (status $isp_rc); backup: $isp_backup" >&2
    if [[ $isp_changed == 1 ]]; then
        if "$isp_backup/restore-isp-kernel.sh" "$isp_backup"; then
            echo 'Original boot files and modules restored.' >&2
        else
            echo "Automatic restore failed; use backup $isp_backup" >&2
        fi
    fi
    exit "$isp_rc"
}
trap isp_failed ERR
trap 'rm -rf -- "$isp_stage"' EXIT
isp_changed=1
make --no-print-directory ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=aarch64-linux-gnu-gcc-11 \
    "O=$isp_output" LOCALVERSION=-rockchip-rk3588 INSTALL_MOD_STRIP=1 modules_install
/usr/sbin/depmod -a "$isp_release"
/usr/sbin/mkinitramfs -o "$isp_stage/initrd.img-$isp_release" "$isp_release"
mkimage -A arm64 -O linux -T ramdisk -C gzip -n uInitrd \
    -d "$isp_stage/initrd.img-$isp_release" "$isp_stage/uInitrd"
cp "$isp_output/arch/arm64/boot/Image" "$isp_stage/Image"
cp "$isp_stage/Image" "$isp_stage/vmlinuz-$isp_release"
cp "$isp_output/System.map" "$isp_stage/System.map-$isp_release"
cp "$isp_output/.config" "$isp_stage/config-$isp_release"
# Activate the new Image last; the existing U-Boot scripts keep loading /boot/Image.
for isp_name in "initrd.img-$isp_release" uInitrd "config-$isp_release" "System.map-$isp_release" "vmlinuz-$isp_release" Image; do
    install -m 0644 "$isp_stage/$isp_name" "/boot/$isp_name.new-isp"
    mv -f -- "/boot/$isp_name.new-isp" "/boot/$isp_name"
done
cmp -s "$isp_output/arch/arm64/boot/Image" /boot/Image
sync
{
    printf 'Kernel release: %s\nBackup: %s\n' "$isp_release" "$isp_backup"
    sha256sum /boot/Image /boot/uInitrd
    printf 'Installation complete. Hardware test is pending reboot.\n'
} | tee "$isp_output/deploy-result.txt"
if [[ $isp_reboot == 1 ]]; then
    /usr/sbin/shutdown -r +1 'OV13855 kernel installed; reboot to test the sensor driver'
    echo 'Reboot scheduled in one minute.'
fi
