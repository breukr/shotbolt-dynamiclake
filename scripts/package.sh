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
# Nor anything of the Mac it was built on: no home folder, no build folder, no source file names. Matched in the shell, not
# with `strings | grep -q`: grep -q stops at the first hit, strings dies of SIGPIPE, and with pipefail a hit reads as clean.
bin_strings=$(strings -a "$pkg/shotbolt-lake")
for needle in "$HOME/" "${HOME:h}/" "$here" .swift; do
  [[ $bin_strings != *"$needle"* ]] || { print -u2 "package.sh: the binary names \"$needle\""; exit 1 }
done
# The manifest and icon as DynamicLake Market checks them ("Plugin Packaging And Market"), so a bad field fails here and not
# in review. Permissions cannot be checked by a script: any listed one is printed, to confirm the plugin really uses it.
/usr/bin/python3 -I - "$pkg" <<'EOF'
import json, pathlib, re, struct, sys, urllib.parse, zlib
pkg = pathlib.Path(sys.argv[1])
manifest = json.loads((pkg / "plugin.json").read_text())
problems = []
def text(value, low, high):
    return isinstance(value, str) and low <= len(value) <= high
if manifest.get("schemaVersion") != 1: problems.append("schemaVersion must be 1")
if not re.fullmatch(r"[A-Za-z0-9._-]{3,128}", str(manifest.get("identifier", ""))):
    problems.append("identifier: 3-128 letters, numbers, '.', '_' or '-'")
if not text(manifest.get("name"), 1, 80): problems.append("name: 1-80 characters")
if not text(manifest.get("version"), 1, 40): problems.append("version: 1-40 characters")
for key in ("executable", "icon"):
    value = manifest.get(key)
    path = pathlib.PurePosixPath(value) if isinstance(value, str) and value else None
    if path is None or path.is_absolute() or ".." in path.parts or not (pkg / value).is_file():
        problems.append(f"{key} must name a file inside the package")
settings = manifest.get("settings", [])
if len(settings) > 24: problems.append(f"{len(settings)} settings, over 24")
for setting in settings:
    sid = str(setting.get("id", ""))
    if not re.fullmatch(r"[A-Za-z][A-Za-z0-9_-]{0,63}", sid): problems.append(f"setting id {sid!r}")
    if not text(setting.get("title"), 1, 80): problems.append(f"{sid}: title 1-80 characters")
    if "description" in setting and not text(setting["description"], 0, 180): problems.append(f"{sid}: description over 180")
    if setting.get("type") == "button":
        if urllib.parse.urlparse(str(setting.get("url", ""))).scheme not in ("http", "https"): problems.append(f"{sid}: url must be http(s)")
        if not text(setting.get("buttonTitle"), 1, 40): problems.append(f"{sid}: buttonTitle 1-40 characters")
if manifest.get("permissions"):
    print(f"package.sh: plugin.json asks for {manifest['permissions']}; list only what the plugin uses", file=sys.stderr)
# The icon: a square PNG, without text chunks (where image tools leave authors, software and file paths) and without
# transparent top corners (DynamicLake rounds the corners itself).
data = (pkg / manifest.get("icon", "icon.png")).read_bytes() if not problems else b""
if data:
    if data[:8] != b"\x89PNG\r\n\x1a\n": problems.append("icon is not a PNG")
    chunks, offset = [], 8
    while offset + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[offset:offset + 8])
        chunks.append((kind, data[offset + 8:offset + 8 + length])); offset += 12 + length
    width, height, depth, color = struct.unpack(">IIBB", chunks[0][1][:10]) if chunks and chunks[0][0] == b"IHDR" else (0, 0, 0, 0)
    if not width or width != height: problems.append(f"icon is {width} x {height}, not square")
    elif width != 512: print(f"package.sh: icon is {width} px; 512 is recommended", file=sys.stderr)
    if any(kind in (b"tEXt", b"zTXt", b"iTXt") for kind, _ in chunks): problems.append("icon has text metadata")
    if color == 6 and depth == 8 and width:
        row = bytearray(zlib.decompress(b"".join(body for kind, body in chunks if kind == b"IDAT"))[:1 + width * 4])
        kind, pixels = row[0], row[1:]
        if kind in (1, 3, 4):  # Sub, Average and Paeth on the first row add (part of) the pixel to the left
            for i in range(4, len(pixels)):
                pixels[i] = (pixels[i] + (pixels[i - 4] if kind != 3 else pixels[i - 4] // 2)) & 255
        if pixels[3] != 255 or pixels[-1] != 255: problems.append("icon has transparent corners; send it square")
if problems:
    print("package.sh: not what DynamicLake Market takes:", *problems, sep="\n  ", file=sys.stderr)
    sys.exit(1)
EOF
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
# Exactly the package folder and its three files, the folder itself at the top: no "._" or __MACOSX entries, nothing else.
listing=$(zipinfo -1 "$zip" | sort)
expected=$(print -l -- "$name.dynamiclakeplugin/"{,icon.png,plugin.json,shotbolt-lake} | sort)
[[ $listing == $expected ]] || { print -u2 "package.sh: the archive holds more or other than the package:"; print -u2 -- "$listing"; exit 1 }
# The checksum file names the zip only, so `shasum -c` works wherever it is downloaded.
(cd "$out" && shasum -a 256 "${zip:t}") | tee "$zip.sha256"
print "package: $pkg"
