#!/bin/sh
# SPDX-License-Identifier: MIT
set -eu
# The entry point runs under Alpine BusyBox ash.
# shellcheck disable=SC3040
set -o pipefail

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[ "$(uname -m)" = aarch64 ] || fail 'An ARM64 runner is required.'
case "$BUILD_PACKAGES" in
    ''|,*|*,|*,,*|*[!a-z0-9,-]*) fail 'Use comma-separated package names.' ;;
esac

# Intentional field splitting after validating the input alphabet.
IFS=,
set -f
# shellcheck disable=SC2086
set -- $BUILD_PACKAGES
set +f
unset IFS
seen=' '
for package in "$@"; do
    [ -f "/src/packages/$package/APKBUILD" ] || fail "Unknown package: $package"
    case "$seen" in *" $package "*) fail "Duplicate package: $package" ;; esac
    seen="$seen$package "
done
case "$SOURCE_DATE_EPOCH" in
    ''|*[!0-9]*) fail 'SOURCE_DATE_EPOCH must be an integer timestamp.' ;;
esac

cat > /etc/apk/repositories <<'REPOSITORIES'
https://mirror.postmarketos.org/postmarketos/extra-repos/systemd/v26.06
https://mirror.postmarketos.org/postmarketos/v26.06
https://dl-cdn.alpinelinux.org/v3.24/main
https://dl-cdn.alpinelinux.org/v3.24/community
REPOSITORIES
install -m 644 /src/keys/build.postmarketos.org.rsa.pub /etc/apk/keys/
apk update
apk upgrade --available
case "$(cat /etc/alpine-release)" in 3.24.*) ;; *) fail 'The container must resolve to Alpine 3.24.' ;; esac
apk add alpine-sdk ccache jq tar binutils doas

adduser -D -u "$BUILD_UID" ci-builder
addgroup ci-builder abuild
printf '%s\n' 'permit nopass :abuild as root cmd mkdir args -p /etc/apk/keys' \
    'permit nopass :abuild as root cmd cp' > /etc/doas.conf
export REPODEST=/work/repo
export ABUILD_LAST_COMMIT="$BUILD_COMMIT"
export CCACHE_DIR=/ccache
export CCACHE_BASEDIR=/work
export USE_CCACHE=1
JOBS=$(nproc)
export JOBS
export CMAKE_BUILD_PARALLEL_LEVEL="$JOBS"
export QT_QPA_PLATFORM=offscreen
export CTEST_OUTPUT_ON_FAILURE=1
printf '\nMAKEFLAGS="-j%s"\nCLEANUP="srcdir bldroot pkgdir"\n' "$JOBS" >> /etc/abuild.conf

local_repo="$REPODEST/packages"
mkdir -p "$local_repo/aarch64"
cp -R /src/packages /work/
chown -R ci-builder /work "$CCACHE_DIR"
su ci-builder -c 'abuild-keygen -a -n -i'
ci_key=$(basename /home/ci-builder/.abuild/*.rsa.pub)
su ci-builder -c "apk --no-network --arch aarch64 index --rewrite-arch aarch64 -o $local_repo/aarch64/APKINDEX.tar.gz"
su ci-builder -c "abuild-sign $local_repo/aarch64/APKINDEX.tar.gz"
printf '%s\n' "$local_repo" >> /etc/apk/repositories

work_files=$(mktemp -d)
cd /out
for package in "$@"; do
    su ci-builder -c "cd /work/packages/$package && abuild -r"
    apk info -v | LC_ALL=C sort > "$work_files/installed"
    jq -Rsc 'split("\n")[:-1]' "$work_files/installed" > "$work_files/$package.installed.json"
    apk del ".makedepends-$package"
done

extract() {
    tar --ignore-zeros --warning=no-unknown-keyword -xOzf "$1" "$2"
}

check_elf() {
    readelf -h "$1" | grep -E 'Machine:[[:space:]]+AArch64$' > /dev/null
}

cp "$local_repo"/aarch64/*.apk .
apk --no-network verify ./*.apk
sha256sum -- ./*.apk | sed 's|  \./|  |' > SHA256SUMS.txt
for archive in ./*.apk; do
    extract "$archive" .PKGINFO > "$work_files/pkginfo"
    package=$(sed -n 's/^pkgname = //p' "$work_files/pkginfo")
    version=$(sed -n 's/^pkgver = //p' "$work_files/pkginfo")
    arch=$(sed -n 's/^arch = //p' "$work_files/pkginfo")
    origin=$(sed -n 's/^origin = //p' "$work_files/pkginfo")
    payload=''
    case "$package" in
        plasma-camera)
            member=usr/bin/plasma-camera
            extract "$archive" "$member" > "$work_files/payload"
            check_elf "$work_files/payload"
            grep -aFq 'gesturePolicy: TapHandler.DragThreshold' "$work_files/payload"
            payload="$member (AArch64, viewfinder tap QML)"
            ;;
        plasma-mobile)
            member=usr/lib/qt6/plugins/plasma/applets/org.kde.plasma.mobile.homescreen.folio.so
            extract "$archive" "$member" > "$work_files/payload"
            check_elf "$work_files/payload"
            strings -a -e b "$work_files/payload" | grep -F FolioHomeScreen.qml > /dev/null
            extract "$archive" usr/lib/udev/rules.d/99-flashlight.rules | cmp - /src/packages/plasma-mobile/99-flashlight.rules
            payload="$member (AArch64, FolioHomeScreen.qml), 99-flashlight.rules"
            ;;
        libcamera)
            member=usr/lib/libcamera.so.0.7.1
            extract "$archive" "$member" > "$work_files/payload"
            check_elf "$work_files/payload"
            payload="$member (AArch64)"
            ;;
    esac
    bytes=$(stat -c %s "$archive")
    hash=$(sha256sum "$archive")
    jq -nc --arg file "${archive#./}" --arg package "$package" --arg version "$version" \
        --arg arch "$arch" --arg origin "$origin" --arg payload "$payload" \
        --argjson bytes "$bytes" --arg sha256 "${hash%% *}" \
        '{file:$file, package:$package, version:$version, arch:$arch, origin:$origin, bytes:$bytes, sha256:$sha256}
         + (if $payload == "" then {} else {payload_check:$payload} end)' >> "$work_files/artifacts.jsonl"
done

for package in "$@"; do
    jq -nec --arg package "$package" --slurpfile installed "$work_files/$package.installed.json" \
        --slurpfile artifacts "$work_files/artifacts.jsonl" \
        '{package:$package, version:($artifacts[] | select(.package==$package) | .version), installed:$installed[0]}' \
        >> "$work_files/builds.jsonl"
done

jq -n --arg commit "$BUILD_COMMIT" --arg architecture "$(uname -m)" --argjson jobs "$JOBS" \
    --arg alpine "$(cat /etc/alpine-release)" --arg image "$BUILD_IMAGE" --arg signing_key "$ci_key" \
    --arg gcc "$(gcc -dumpfullversion)" --arg gxx "$(g++ -dumpfullversion)" \
    --argjson source_date_epoch "$SOURCE_DATE_EPOCH" --slurpfile packages "$work_files/builds.jsonl" \
    --slurpfile artifacts "$work_files/artifacts.jsonl" \
    '{schema:1, commit:$commit, architecture:$architecture, jobs:$jobs, alpine:$alpine, postmarketos:"v26.06",
      image:$image, signing_key:$signing_key, source_date_epoch:$source_date_epoch,
      compilers:{gcc:$gcc,gxx:$gxx}, packages:$packages, artifacts:$artifacts}' > build-manifest.json
su ci-builder -c 'ccache --show-stats'
