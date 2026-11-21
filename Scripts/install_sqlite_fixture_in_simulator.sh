#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"
fixture_path="${1:-${project_root}/.local-test-data/device-index/travel-index-v3.sqlite}"
bundle_identifier="com.doupi.PhotoEarth.PhotoEarth"

if [[ ! -f "${fixture_path}" ]]; then
  print -u2 "SQLite fixture not found: ${fixture_path}"
  exit 1
fi

integrity="$(sqlite3 "${fixture_path}" 'PRAGMA integrity_check;')"
schema_version="$(sqlite3 "${fixture_path}" "SELECT value FROM metadata WHERE key = 'schema_version';")"
if [[ "${integrity}" != "ok" || "${schema_version}" != "3" ]]; then
  print -u2 "Fixture rejected: integrity=${integrity}, schema=${schema_version}"
  exit 1
fi

simulator_container="$(xcrun simctl get_app_container booted "${bundle_identifier}" data 2>/dev/null || true)"
if [[ -z "${simulator_container}" ]]; then
  print -u2 "PhotoEarth is not installed in the booted Apple TV Simulator. Build or run it once first."
  exit 1
fi

xcrun simctl terminate booted "${bundle_identifier}" 2>/dev/null || true

destination_directory="${simulator_container}/Library/Caches/PhotoEarth"
destination_database="${destination_directory}/travel-index-v3.sqlite"
mkdir -p "${destination_directory}"

if [[ -f "${destination_database}" ]]; then
  backup_directory="${project_root}/.local-test-data/simulator-index-backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${backup_directory}"
  cp "${destination_database}" "${backup_directory}/travel-index-v3.sqlite"
  [[ ! -f "${destination_database}-wal" ]] || cp "${destination_database}-wal" "${backup_directory}/travel-index-v3.sqlite-wal"
  [[ ! -f "${destination_database}-shm" ]] || cp "${destination_database}-shm" "${backup_directory}/travel-index-v3.sqlite-shm"
  print "Backed up the previous simulator index to ${backup_directory}"
fi

incoming_database="${destination_directory}/travel-index-v3.sqlite.incoming"
cp "${fixture_path}" "${incoming_database}"
rm -f "${destination_database}-wal" "${destination_database}-shm"
mv "${incoming_database}" "${destination_database}"

counts="$(sqlite3 "${destination_database}" "SELECT COUNT(*) || ' photos, ' || (SELECT COUNT(*) FROM places) || ' places, ' || (SELECT COUNT(*) FROM journeys) || ' journeys' FROM photos;")"
print "Installed simulator SQLite fixture: ${counts}"
print "Launch PhotoEarth from Xcode or run: xcrun simctl launch booted ${bundle_identifier}"
