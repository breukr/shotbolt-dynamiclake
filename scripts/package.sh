#!/bin/zsh
# Builds the DynamicLake plugin package: a universal shotbolt-lake, the manifest and the icon in
# build/Shotbolt.dynamiclakeplugin, zipped for DynamicLake Market with its SHA-256.
#
#   scripts/package.sh                                           ad-hoc signed, for a local install
#   scripts/package.sh --sign "Developer ID Application: …"      signed with hardened runtime and a timestamp
#
# For testing, install the .dynamiclakeplugin folder from DynamicLake's settings (Install Local).
set -euo pipefail
here=${0:A:h:h}
cd "$here"

identity="-"
name=Shotbolt
build=(-c release --arch arm64 --arch x86_64)
while (( $# )); do
  case $1 in
    --sign) identity=$2; shift 2 ;;
    *) print -u2 "package.sh: unknown option $1"; exit 64 ;;
  esac
done

swift build "${build[@]}" --product shotbolt-lake
bin="$(swift build "${build[@]}" --show-bin-path)/shotbolt-lake"

out="$here/build"
pkg="$out/$name.dynamiclakeplugin"
rm -rf "$pkg"
mkdir -p "$pkg"
cp Package/Shotbolt.dynamiclakeplugin/icon.png "$pkg/"
cp Package/Shotbolt.dynamiclakeplugin/plugin.json "$pkg/"
cp "$bin" "$pkg/shotbolt-lake"
# Every symbol out: the binary keeps only what dyld needs, not the names of the plugin's own functions.
strip "$pkg/shotbolt-lake"
version=$(/usr/bin/python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$pkg/plugin.json")

if [[ $identity == "-" ]]; then
  codesign --force --sign - "$pkg/shotbolt-lake"
else
  codesign --force --sign "$identity" --options runtime --timestamp "$pkg/shotbolt-lake"
fi
codesign --verify --strict "$pkg/shotbolt-lake"
# One architecture per check: Xcode 27's lipo reads a second name after -verify_arch as another input file.
for arch in arm64 x86_64; do lipo "$pkg/shotbolt-lake" -verify_arch $arch; done

# DynamicLake Market's limits: archive 7 MB, package 20 MB, manifest 128 KB, icon 1.5 MB.
(( $(stat -f %z "$pkg/plugin.json") <= 131072 )) || { print -u2 "plugin.json is over 128 KB"; exit 1 }
(( $(stat -f %z "$pkg/icon.png") <= 1572864 )) || { print -u2 "icon.png is over 1.5 MB"; exit 1 }
(( $(du -sk "$pkg" | cut -f1) <= 20480 )) || { print -u2 "the package is over 20 MB"; exit 1 }

zip="$out/${name// /-}-$version.zip"
rm -f "$zip"
# No macOS metadata in the archive (no "._" files with extended attributes): only the three files of the package.
(cd "$out" && ditto -c -k --norsrc --noextattr --noacl --keepParent "$name.dynamiclakeplugin" "$zip")
(( $(stat -f %z "$zip") <= 7340032 )) || { print -u2 "the archive is over 7 MB"; exit 1 }
# The checksum file names the zip only, so `shasum -c` works wherever it is downloaded.
(cd "$out" && shasum -a 256 "${zip:t}") | tee "$zip.sha256"
print "package: $pkg"
