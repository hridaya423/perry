#!/bin/sh
set -eu

[ "$#" -eq 1 ] || { echo "usage: prepare-release-output.sh /absolute/output/directory" >&2; exit 1; }
output_directory="$1"
case "${output_directory}" in
  /*) ;;
  *) echo "release output: an absolute path is required" >&2; exit 1 ;;
esac

mkdir -p "$(dirname -- "${output_directory}")"
if ! mkdir "${output_directory}"; then
  echo "release output: could not reserve a new directory; check the path and permissions. Existing artifacts will not be overwritten" >&2
  exit 1
fi
