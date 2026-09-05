#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'Usage: %s <exported-openapi.json>\n' "$0" >&2
    exit 64
fi

script_directory=$(CDPATH= cd "$(dirname "$0")" && pwd)
component_root=$(CDPATH= cd "$script_directory/.." && pwd)
source_snapshot=$1
destination_snapshot="$component_root/Sources/MosemoAPI/openapi.json"
generated_sources="$component_root/Sources/MosemoAPI/GeneratedSources"
developer_directory=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}

if [ ! -f "$source_snapshot" ]; then
    printf 'OpenAPI artifact not found: %s\n' "$source_snapshot" >&2
    exit 66
fi

if [ ! -d "$developer_directory" ]; then
    printf 'Xcode developer directory not found: %s\n' "$developer_directory" >&2
    exit 69
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'jq is required to validate the OpenAPI artifact.\n' >&2
    exit 69
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/mosemo-openapi.XXXXXX")
candidate_snapshot="$temporary_directory/openapi.json"
previous_snapshot="$temporary_directory/previous-openapi.json"
previous_generated_sources="$temporary_directory/previous-generated-sources"
replacement_snapshot="$destination_snapshot.next"
installed=0
had_previous=0
generation_started=0
had_previous_generation=0
succeeded=0

cleanup() {
    if [ "$installed" -eq 1 ] && [ "$succeeded" -eq 0 ]; then
        if [ "$had_previous" -eq 1 ]; then
            cp "$previous_snapshot" "$replacement_snapshot"
            mv "$replacement_snapshot" "$destination_snapshot"
        else
            rm -f "$destination_snapshot"
        fi
        if [ "$generation_started" -eq 1 ]; then
            rm -rf "$generated_sources"
            if [ "$had_previous_generation" -eq 1 ]; then
                cp -R "$previous_generated_sources" "$generated_sources"
            fi
        fi
        printf 'Restored the previous OpenAPI snapshot after verification failed.\n' >&2
    fi
    rm -f "$replacement_snapshot"
    rm -rf "$temporary_directory"
}
trap cleanup EXIT HUP INT TERM

cp "$source_snapshot" "$candidate_snapshot"

jq -e '
    (.openapi | type == "string" and startswith("3.1.")) and
    (.paths["/api/v1/auth/token"].post.operationId
        == "exchange_token_api_v1_auth_token_post") and
    (.paths["/api/v1/auth/token"].post.responses["200"] != null) and
    (.paths["/api/v1/auth/token"].post.responses["400"] != null) and
    (.paths["/api/v1/auth/token"].post.responses["422"] != null) and
    (.paths["/api/v1/accounts/me"].get.operationId
        == "get_me_api_v1_accounts_me_get") and
    (.paths["/api/v1/accounts/me"].get.responses["200"] != null) and
    (.paths["/api/v1/accounts/me"].get.responses["401"] != null)
' "$candidate_snapshot" >/dev/null

if [ -f "$destination_snapshot" ]; then
    cp "$destination_snapshot" "$previous_snapshot"
    had_previous=1
fi

cp "$candidate_snapshot" "$replacement_snapshot"
mv "$replacement_snapshot" "$destination_snapshot"
installed=1

if [ -d "$generated_sources" ]; then
    cp -R "$generated_sources" "$previous_generated_sources"
    had_previous_generation=1
fi
generation_started=1

(
    cd "$component_root"
    DEVELOPER_DIR="$developer_directory" xcrun swift package \
        --allow-writing-to-package-directory \
        generate-code-from-openapi \
        --target MosemoAPI
    DEVELOPER_DIR="$developer_directory" xcrun swift build --target MosemoAPI
    DEVELOPER_DIR="$developer_directory" xcrun swift test
)

succeeded=1
printf 'Updated and verified %s\n' "$destination_snapshot"
