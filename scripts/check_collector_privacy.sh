#!/bin/sh
set -eu

script_directory=$(CDPATH= cd "$(dirname "$0")" && pwd)
component_root=$(CDPATH= cd "$script_directory/.." && pwd)
production_sources="$component_root/Sources"
info_plist="$component_root/Info.plist"
openapi_contract="$component_root/../mosemo-server/openapi/openapi.json"
failed=0

if ! command -v rg >/dev/null 2>&1; then
    printf 'FAIL: ripgrep (rg) is required for the collector privacy checks.\n' >&2
    exit 69
fi

if [ ! -f "$openapi_contract" ]; then
    printf 'FAIL: Server OpenAPI contract not found: %s\n' "$openapi_contract" >&2
    exit 66
fi

check_absent() {
    label=$1
    pattern=$2
    shift 2
    if rg -n --glob '*.swift' --glob '*.plist' --glob '*.json' "$pattern" "$@"; then
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
    "network APIs are absent from CollectorCore" \
    'URLSession|NWConnection|Network\.framework' \
    "$production_sources/CollectorCore"

check_absent \
    "database APIs are absent from the UI and domain layers" \
    'SQLite|CoreData|NSPersistentContainer' \
    "$production_sources/CollectorCore" \
    "$production_sources/MosemoApp"

if rg -n --glob '*.swift' 'SQLite|CoreData|NSPersistentContainer' \
    "$production_sources/MosemoAPI" \
    | rg -v '/(SQLiteStorage|EncryptedActivityQueue)\.swift:'; then
    printf 'FAIL: database APIs are confined to storage adapters\n' >&2
    failed=1
else
    printf 'PASS: database APIs are confined to storage adapters\n'
fi

check_absent \
    "persistent diagnostic file writes are absent" \
    'FileHandle|write\(to:|createFile\(|PropertyListEncoder|JSONEncoder\(\).*write' \
    "$production_sources"

if rg -n --glob '*.swift' 'UserDefaults' "$production_sources" \
    | rg -v '^.*/MosemoApp/CollectorViewModel\.swift:[0-9]+:[[:space:]]*(let savedTrackingPreference = UserDefaults\.standard\.object\(forKey: Self\.activityTrackingPreferenceKey\) as\? Bool|UserDefaults\.standard\.set\(enabled, forKey: Self\.activityTrackingPreferenceKey\))$'; then
    printf 'FAIL: only the activity tracking preference may use UserDefaults\n' >&2
    failed=1
elif rg -q --fixed-strings \
    'private static let activityTrackingPreferenceKey = "io.mosemo.activityTrackingEnabled"' \
    "$production_sources/MosemoApp/CollectorViewModel.swift"; then
    printf 'PASS: only the activity tracking preference uses UserDefaults\n'
else
    printf 'FAIL: activity tracking preference key changed\n' >&2
    failed=1
fi

check_absent \
    "application logging calls are absent" \
    '(^|[^[:alnum:]_])(print|debugPrint|NSLog|os_log)\(|Logger\(' \
    "$production_sources"

check_absent \
    "authentication secrets are absent from logging arguments" \
    '(print|debugPrint|NSLog|os_log|Logger).*\b(accessToken|authorizationCode|codeVerifier|callbackURL)\b' \
    "$production_sources"

check_absent \
    "forbidden payload field names are absent from safe core models" \
    'fullURL|pageTitle|keyContents|clickCoordinates|mousePath|screenImage|pageBody|formValue' \
    "$production_sources/CollectorCore" \
    "$openapi_contract"

if [ "$failed" -ne 0 ]; then
    exit 1
fi

printf 'Collector privacy static checks passed.\n'
