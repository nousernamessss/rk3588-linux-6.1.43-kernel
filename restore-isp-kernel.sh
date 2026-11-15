#!/usr/bin/env bash
# Restore one backup made by deploy-isp-kernel.sh. Does not reboot.
set -euo pipefail
[[ $EUID == 0 ]] || { echo 'Run with sudo' >&2; exit 1; }
[[ $# == 1 ]] || { echo 'Usage: sudo ./restore-isp-kernel.sh BACKUP_DIRECTORY' >&2; exit 2; }
isp_backup=$(realpath -- "$1")
isp_release=6.1.43-rockchip-rk3588
[[ -f "$isp_backup/backup-complete" && -d "$isp_backup/modules/$isp_release" ]] || { echo 'Incomplete backup' >&2; exit 1; }
if [[ -d "/lib/modules/$isp_release" ]]; then
    isp_replaced=$(mktemp -d "$isp_backup/replaced-modules.XXXXXX")
    mv "/lib/modules/$isp_release" "$isp_replaced/$isp_release"
fi
cp -a "$isp_backup/modules/$isp_release" /lib/modules/
while IFS= read -r isp_name; do
    case "$isp_name" in */*|'') echo 'Invalid backup filename' >&2; exit 1 ;; esac
    cp -a -- "$isp_backup/boot/$isp_name" "/boot/$isp_name.restore-isp"
    mv -f -- "/boot/$isp_name.restore-isp" "/boot/$isp_name"
done < "$isp_backup/boot-files.list"
while IFS= read -r isp_name; do
    case "$isp_name" in */*|'') echo 'Invalid backup filename' >&2; exit 1 ;; esac
    rm -f -- "/boot/$isp_name"
done < "$isp_backup/boot-files-absent.list"
/usr/sbin/depmod -a "$isp_release"
sync
echo "Restored kernel and modules from $isp_backup"
