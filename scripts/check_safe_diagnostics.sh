#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf 'usage: %s <safe-diagnostics.txt>\n' "$0" >&2
    exit 2
fi

diagnostics_file=$1
forbidden_pattern='://|[[:alnum:]_.-]+\.[[:alpha:]]{2,}/|fullURL|pageTitle|keyContents|clickCoordinates|mousePath|screenImage|pageBody|formValue|query=|fragment='

if rg -n -i "$forbidden_pattern" "$diagnostics_file"; then
    printf 'FAIL: possible forbidden data found in %s\n' "$diagnostics_file" >&2
    exit 1
fi

printf 'PASS: no forbidden diagnostic pattern found in %s\n' "$diagnostics_file"
