#!/usr/bin/env bash
# Build the Orange Pi 5 Plus kernel on the board or in Ubuntu/WSL2.
set -euo pipefail

isp_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
cd "$isp_root"
isp_output=$(realpath -m -- "${ISP_BUILD_DIR:-build-ov13855-testpattern}")
isp_jobs=${ISP_BUILD_JOBS:-4}
isp_prefix=${ISP_CROSS_COMPILE:-aarch64-linux-gnu-}
isp_cc=${ISP_CC:-${isp_prefix}gcc-11}
isp_release=6.1.43-rockchip-rk3588

if [[ ${1:-} == --help ]]; then
    echo 'Usage: ./build-isp-kernel.sh'
    echo 'Optional: ISP_BUILD_JOBS=8 ISP_BUILD_DIR=build-pc ISP_CC=aarch64-linux-gnu-gcc-11'
    exit 0
fi
[[ $# == 0 ]] || { echo 'Unexpected argument; use --help' >&2; exit 2; }
[[ "$isp_jobs" =~ ^[1-9][0-9]*$ ]] || { echo 'Invalid ISP_BUILD_JOBS' >&2; exit 2; }
[[ "$isp_output" != "$isp_root" ]] || { echo 'Choose a separate build directory' >&2; exit 2; }
command -v make >/dev/null
command -v "$isp_cc" >/dev/null
[[ $("$isp_cc" -dumpmachine) == aarch64* ]] || { echo 'Expected an AArch64 compiler' >&2; exit 1; }
mkdir -p "$isp_output"
if [[ ! -f "$isp_output/.config" ]]; then
    cp configs/isp-rk3588.config "$isp_output/.config"
fi
isp_make=(ARCH=arm64 "CROSS_COMPILE=$isp_prefix" "CC=$isp_cc" "O=$isp_output" LOCALVERSION=-rockchip-rk3588)
make --no-print-directory "${isp_make[@]}" olddefconfig
isp_actual=$(make --no-print-directory -s "${isp_make[@]}" kernelrelease)
[[ "$isp_actual" == "$isp_release" ]] || { echo "Unexpected kernel release: $isp_actual" >&2; exit 1; }
make --no-print-directory -j"$isp_jobs" "${isp_make[@]}" Image modules 2>&1 | tee "$isp_output/build.log"
sha256sum "$isp_output/arch/arm64/boot/Image" > "$isp_output/Image.sha256"
printf '\nBuilt %s\nImage: %s/arch/arm64/boot/Image\nLog: %s/build.log\n' "$isp_release" "$isp_output" "$isp_output"
