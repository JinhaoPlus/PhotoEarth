"""Read reviewed source relationships separately from the database under test."""

import csv
import gzip
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PARENTS = ROOT.parents[1] / "camera_photo_geo/Tools/journey-catalog/world-city-parents.tsv"
BASELINE = ROOT / "Scripts/Fixtures/WorldCityAtlas-20261121.4-public.tsv.gz"


def read_parents(path):
    with path.open(newline="", encoding="utf-8") as stream:
        reader = csv.DictReader(stream, delimiter="\t")
        if reader.fieldnames != ["child_id", "city_id", "region", "source"]:
            raise ValueError(f"Unexpected parent relationship schema in {path}")
        parents = {}
        for row in reader:
            child, city, region, source = (row[key] for key in reader.fieldnames)
            if not all((child, city, region, source)) or child == city or child in parents:
                raise ValueError(f"Invalid parent relationship for {child} in {path}")
            parents[child] = (city, region)
    for child, (city, _) in parents.items():
        if city in parents:
            raise ValueError(f"Expected a final city for {child}, found intermediate place {city}")
    return parents


def public_baseline():
    with gzip.open(BASELINE, "rt", newline="", encoding="utf-8") as stream:
        rows = list(csv.DictReader(stream, delimiter="\t"))
    result = {(row["sample"], row["source_id"], row["latitude"], row["longitude"]): row for row in rows}
    if len(result) != 2466 or len(rows) != 2466:
        raise ValueError("Incomplete .4 public-coordinate fixture")
    return result
