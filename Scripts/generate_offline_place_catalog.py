#!/usr/bin/env python3
"""Export an optional historical development fixture from Natural Earth 5.1.2.

Usage:
  python3 -m pip install pyshp
  ./Scripts/generate_offline_place_catalog.py path/to/ne_10m_populated_places output.tsv

The input may be the shapefile base path or its .shp/.dbf path. The single-database
app and the production builder do not read this historical export.
"""

from pathlib import Path
import sys

import shapefile

NATURAL_EARTH_VERSION = "5.1.2"
EXPECTED_RECORD_COUNT = 7_342
NAME_FIELDS = (
    "NAMEASCII", "NAME_EN", "NAME_DE", "NAME_ES", "NAME_FR",
    "NAME_IT", "NAME_PT", "NAME_JA", "NAME_ZH", "NAME_ZHT",
)


def clean(value: object) -> str:
    return str(value or "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def main() -> int:
    if len(sys.argv) != 3:
        print("expected a Natural Earth populated-places shapefile path and a destination file", file=sys.stderr)
        return 2

    source = Path(sys.argv[1]).with_suffix("")
    destination = Path(sys.argv[2])
    reader = shapefile.Reader(str(source))

    available_fields = {field[0] for field in reader.fields[1:]}
    required_fields = {"NE_ID", "LATITUDE", "LONGITUDE", "ISO_A2", "ADM0NAME", *NAME_FIELDS}
    missing_fields = required_fields - available_fields
    if missing_fields:
        raise ValueError(f"Natural Earth input is missing fields: {sorted(missing_fields)}")

    rows: list[tuple] = []
    place_ids: set[str] = set()
    for record in reader.records():
        fields = record.as_dict()
        place_id = clean(fields.get("NE_ID"))
        if not place_id or place_id in place_ids:
            raise ValueError(f"missing or duplicate Natural Earth ID: {place_id!r}")
        place_ids.add(place_id)
        latitude = float(fields["LATITUDE"])
        longitude = float(fields["LONGITUDE"])
        if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
            raise ValueError(f"invalid coordinate for {place_id}: {latitude}, {longitude}")
        region_code = clean(fields.get("ISO_A2"))
        if region_code == "-99":
            region_code = ""
        if region_code and (len(region_code) != 2 or not region_code.isalpha()):
            raise ValueError(f"invalid ISO_A2 for {place_id}: {region_code!r}")
        names = tuple(clean(fields.get(field)) for field in NAME_FIELDS)
        if any(not name for name in names):
            missing_names = [field for field, name in zip(NAME_FIELDS, names) if not name]
            raise ValueError(f"missing localized names for {place_id}: {missing_names}")
        ascii_name = names[0] or clean(fields.get("NAME"))
        rows.append((
            place_id,
            latitude,
            longitude,
            region_code,
            clean(fields.get("ADM0NAME")),
            ascii_name,
            *(name or ascii_name for name in names[1:]),
        ))

    if len(rows) != EXPECTED_RECORD_COUNT:
        raise ValueError(
            f"Natural Earth {NATURAL_EARTH_VERSION} should contain "
            f"{EXPECTED_RECORD_COUNT} records, found {len(rows)}"
        )
    rows.sort(key=lambda row: (row[1], row[2], row[5], row[3], row[0]))
    with destination.open("w", encoding="utf-8", newline="\n") as output:
        output.write("# Natural Earth 1:10m Populated Places 5.1.2; public domain\n")
        output.write("# ne_id<TAB>latitude<TAB>longitude<TAB>ISO-3166-1 alpha-2<TAB>country fallback<TAB>name_ascii<TAB>name_en<TAB>name_de<TAB>name_es<TAB>name_fr<TAB>name_it<TAB>name_pt<TAB>name_ja<TAB>name_zh<TAB>name_zht\n")
        for row in rows:
            place_id, latitude, longitude, *columns = row
            output.write(f"{place_id}\t{latitude:.6f}\t{longitude:.6f}\t" + "\t".join(columns) + "\n")

    print(f"wrote {len(rows)} places to {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
