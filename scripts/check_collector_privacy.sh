#!/bin/sh
set -eu

script_directory=$(CDPATH= cd "$(dirname "$0")" && pwd)
component_root=$(CDPATH= cd "$script_directory/.." && pwd)
production_sources="$component_root/Sources"
info_plist="$component_root/Info.plist"
failed=0

check_absent() {
    label=$1
    pattern=$2
    shift 2
    if rg -n --glob '*.swift' --glob '*.plist' "$pattern" "$@"; then
        printf 'FAIL: %s\n' "$label" >&2
        failed=1
    else
        printf 'PASS: %s\n' "$label"
    fi
}

check_absent \
    "screen capture APIs and permission key are absent" \
    'NSScreenCaptureUsageDescription|ScreenCaptureKit|SCStream|CGWindowListCreateImage|CGDisplayStream|AVCaptureScreenInput' \
    "$production_sources" "$info_plist"

check_absent \
    "network and database APIs are absent" \
    'URLSession|NWConnection|Network\.framework|SQLite|CoreData|NSPersistentContainer' \
    "$production_sources"

check_absent \
    "persistent file and preference writes are absent" \
    'UserDefaults|FileHandle|write\(to:|createFile\(|PropertyListEncoder|JSONEncoder\(\).*write' \
    "$production_sources"

check_absent \
    "application logging calls are absent" \
    '(^|[^[:alnum:]_])(print|debugPrint|NSLog|os_log)\(|Logger\(' \
    "$production_sources"

check_absent \
    "forbidden payload field names are absent from safe core models" \
    'fullURL|pageTitle|keyContents|clickCoordinates|mousePath|screenImage|pageBody|formValue' \
    "$production_sources/CollectorCore"

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf 'Collector privacy static checks passed.\n'
