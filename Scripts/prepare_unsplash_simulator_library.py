#!/usr/bin/env python3
"""Build and optionally import a geotagged tvOS PhotoKit stress-test library.

The official Unsplash API is used to find three landscape photos for each of ten
destinations. Every API photo download is registered through Unsplash's
download_location endpoint. Ten local derivatives are made from every source,
giving 300 simulator assets while staying inside the default 50-request/hour
demo allowance (10 searches + 30 tracked downloads).

Downloaded source files and generated fixtures stay under .local-test-data,
which is intentionally ignored by Git. A manifest keeps photographer and source
attribution alongside the generated assets. Synthetic GPS is written only when
the downloaded image has no embedded GPS metadata.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import random
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterable

from PIL import ExifTags, Image, ImageOps
from PIL.TiffImagePlugin import IFDRational


SCRIPT_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_ENV_PATH = SCRIPT_ROOT / ".env.unsplash.local"
DEFAULT_OUTPUT_ROOT = SCRIPT_ROOT / ".local-test-data" / "unsplash-global-300"
API_BASE = "https://api.unsplash.com"
USER_AGENT = "PhotoEarthLocalFixtureBuilder/1.0"


@dataclass(frozen=True)
class Destination:
    slug: str
    query: str
    city: str
    country: str
    latitude: float
    longitude: float
    visit_start: str


DESTINATIONS = (
    Destination("reykjavik", "Reykjavik Iceland travel", "Reykjavik", "Iceland", 64.1466, -21.9426, "2016-02-12"),
    Destination("paris", "Paris France travel landmark", "Paris", "France", 48.8566, 2.3522, "2017-05-18"),
    Destination("tokyo", "Tokyo Japan travel city", "Tokyo", "Japan", 35.6762, 139.6503, "2018-04-03"),
    Destination("new-york", "New York City travel", "New York", "United States", 40.7128, -74.0060, "2019-09-14"),
    Destination("singapore", "Singapore travel skyline", "Singapore", "Singapore", 1.3521, 103.8198, "2020-01-21"),
    Destination("istanbul", "Istanbul Turkey travel", "Istanbul", "Türkiye", 41.0082, 28.9784, "2021-10-07"),
    Destination("cape-town", "Cape Town South Africa travel", "Cape Town", "South Africa", -33.9249, 18.4241, "2022-03-11"),
    Destination("rio", "Rio de Janeiro Brazil travel", "Rio de Janeiro", "Brazil", -22.9068, -43.1729, "2023-02-22"),
    Destination("banff", "Banff Canada mountains travel", "Banff", "Canada", 51.1784, -115.5708, "2024-08-09"),
    Destination("sydney", "Sydney Australia travel harbour", "Sydney", "Australia", -33.8688, 151.2093, "2025-12-16"),
)

PHOTOS_PER_DESTINATION = 3
DERIVATIVES_PER_PHOTO = 10
EXPECTED_ASSET_COUNT = len(DESTINATIONS) * PHOTOS_PER_DESTINATION * DERIVATIVES_PER_PHOTO


@dataclass(frozen=True)
class FixtureRecord:
    file: str
    unsplash_id: str
    photographer: str
    photographer_url: str
    photo_url: str
    city: str
    country: str
    latitude: float
    longitude: float
    captured_at: str
    gps_source: str
    source_had_embedded_gps: bool


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--env", type=Path, default=DEFAULT_ENV_PATH)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument(
        "--import-simulator",
        action="store_true",
        help="Import all generated JPEGs into the currently booted simulator.",
    )
    parser.add_argument(
        "--refresh-selection",
        action="store_true",
        help="Discard the cached API selection and search again (uses 10 requests).",
    )
    return parser.parse_args()


def read_env_value(path: Path, key: str) -> str | None:
    if not path.exists():
        return os.environ.get(key)

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        if name.strip() == key:
            return value.strip().strip('"').strip("'")
    return os.environ.get(key)


def api_json(path_or_url: str, access_key: str) -> Any:
    url = path_or_url if path_or_url.startswith("https://") else f"{API_BASE}{path_or_url}"
    request = urllib.request.Request(
        url,
        headers={
            "Accept-Version": "v1",
            "Authorization": f"Client-ID {access_key}",
            "User-Agent": USER_AGENT,
        },
    )
    for attempt in range(1, 5):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            detail = error.read().decode("utf-8", errors="replace")
            if error.code < 500 or attempt == 4:
                raise RuntimeError(f"Unsplash API returned HTTP {error.code}: {detail[:400]}") from error
        except urllib.error.URLError:
            if attempt == 4:
                raise
        time.sleep(2**attempt)

    raise RuntimeError("Unsplash API retry loop ended unexpectedly")


def download_file(url: str, destination: Path) -> None:
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    temporary = destination.with_suffix(destination.suffix + ".partial")
    for attempt in range(1, 6):
        try:
            with urllib.request.urlopen(request, timeout=90) as response, temporary.open("wb") as output:
                while chunk := response.read(1024 * 1024):
                    output.write(chunk)
            temporary.replace(destination)
            return
        except (urllib.error.URLError, TimeoutError, ConnectionError):
            temporary.unlink(missing_ok=True)
            if attempt == 5:
                raise
            print(f"Download interrupted; retrying in {2**attempt}s ({attempt}/5)")
            time.sleep(2**attempt)
        finally:
            temporary.unlink(missing_ok=True)


def save_json_atomic(path: Path, value: Any) -> None:
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def select_photos(access_key: str, cache_path: Path, refresh: bool) -> dict[str, list[dict[str, Any]]]:
    if cache_path.exists() and not refresh:
        return json.loads(cache_path.read_text(encoding="utf-8"))

    selected: dict[str, list[dict[str, Any]]] = {}
    used_ids: set[str] = set()

    for destination in DESTINATIONS:
        parameters = urllib.parse.urlencode(
            {
                "query": destination.query,
                "page": 1,
                "per_page": 10,
                "orientation": "landscape",
                "content_filter": "high",
            }
        )
        payload = api_json(f"/search/photos?{parameters}", access_key)
        candidates = [photo for photo in payload.get("results", []) if photo.get("id") not in used_ids]
        if len(candidates) < PHOTOS_PER_DESTINATION:
            raise RuntimeError(f"Not enough unique Unsplash results for {destination.city}.")
        chosen = candidates[:PHOTOS_PER_DESTINATION]
        selected[destination.slug] = chosen
        used_ids.update(photo["id"] for photo in chosen)
        print(f"Selected {len(chosen)} photos for {destination.city}")
        time.sleep(0.15)

    save_json_atomic(cache_path, selected)
    return selected


def rational_degrees(value: float) -> tuple[IFDRational, IFDRational, IFDRational]:
    absolute = abs(value)
    degrees = math.floor(absolute)
    minutes_float = (absolute - degrees) * 60
    minutes = math.floor(minutes_float)
    seconds = (minutes_float - minutes) * 60
    return IFDRational(degrees, 1), IFDRational(minutes, 1), IFDRational(round(seconds * 10_000), 10_000)


def degrees_from_rationals(values: Iterable[Any]) -> float:
    degrees, minutes, seconds = (float(value) for value in values)
    return degrees + minutes / 60 + seconds / 3600


def embedded_gps(image: Image.Image) -> tuple[float, float] | None:
    exif = image.getexif()
    if not exif:
        return None
    try:
        gps = exif.get_ifd(ExifTags.IFD.GPSInfo)
        latitude_values = gps.get(ExifTags.GPS.GPSLatitude)
        longitude_values = gps.get(ExifTags.GPS.GPSLongitude)
        if not latitude_values or not longitude_values:
            return None
        latitude = degrees_from_rationals(latitude_values)
        longitude = degrees_from_rationals(longitude_values)
        if gps.get(ExifTags.GPS.GPSLatitudeRef, "N") == "S":
            latitude *= -1
        if gps.get(ExifTags.GPS.GPSLongitudeRef, "E") == "W":
            longitude *= -1
        return latitude, longitude
    except (KeyError, TypeError, ValueError, ZeroDivisionError):
        return None


def write_fixture_image(
    source_path: Path,
    destination_path: Path,
    latitude: float,
    longitude: float,
    captured_at: datetime,
) -> tuple[float, float, bool]:
    with Image.open(source_path) as source:
        source.load()
        original_gps = embedded_gps(source)
        final_latitude, final_longitude = original_gps or (latitude, longitude)
        image = ImageOps.exif_transpose(source).convert("RGB")
        exif = source.getexif()

        gps_ifd = dict(exif.get_ifd(ExifTags.IFD.GPSInfo)) if exif else {}
        if original_gps is None:
            gps_ifd[ExifTags.GPS.GPSLatitudeRef] = "N" if final_latitude >= 0 else "S"
            gps_ifd[ExifTags.GPS.GPSLatitude] = rational_degrees(final_latitude)
            gps_ifd[ExifTags.GPS.GPSLongitudeRef] = "E" if final_longitude >= 0 else "W"
            gps_ifd[ExifTags.GPS.GPSLongitude] = rational_degrees(final_longitude)
            gps_ifd[ExifTags.GPS.GPSMapDatum] = "WGS-84"
            gps_ifd[ExifTags.GPS.GPSDateStamp] = captured_at.strftime("%Y:%m:%d")
            gps_ifd[ExifTags.GPS.GPSTimeStamp] = (
                IFDRational(captured_at.hour, 1),
                IFDRational(captured_at.minute, 1),
                IFDRational(captured_at.second, 1),
            )
            exif[ExifTags.IFD.GPSInfo] = gps_ifd

        captured_value = captured_at.strftime("%Y:%m:%d %H:%M:%S")
        exif_ifd = dict(exif.get_ifd(ExifTags.IFD.Exif)) if exif else {}
        exif_ifd[ExifTags.Base.DateTimeOriginal] = captured_value
        exif_ifd[ExifTags.Base.DateTimeDigitized] = captured_value
        exif[ExifTags.IFD.Exif] = exif_ifd
        exif[ExifTags.Base.DateTime] = captured_value
        exif[ExifTags.Base.ImageDescription] = "Photo Earth synthetic travel performance fixture"

        image.save(destination_path, "JPEG", quality=82, optimize=True, exif=exif)

    with Image.open(destination_path) as verification_image:
        verified_gps = embedded_gps(verification_image)
    if verified_gps is None:
        raise RuntimeError(f"GPS verification failed for {destination_path.name}")
    return verified_gps[0], verified_gps[1], original_gps is not None


def deterministic_jitter(destination: Destination, photo_id: str, derivative_index: int) -> tuple[float, float]:
    seed_material = f"{destination.slug}:{photo_id}:{derivative_index}".encode("utf-8")
    seed = int.from_bytes(hashlib.sha256(seed_material).digest()[:8], "big")
    randomizer = random.Random(seed)
    return (
        destination.latitude + randomizer.uniform(-0.018, 0.018),
        destination.longitude + randomizer.uniform(-0.022, 0.022),
    )


def build_fixtures(
    access_key: str,
    output_root: Path,
    selection: dict[str, list[dict[str, Any]]],
) -> list[FixtureRecord]:
    source_root = output_root / "sources"
    fixture_root = output_root / "photos"
    source_root.mkdir(parents=True, exist_ok=True)
    fixture_root.mkdir(parents=True, exist_ok=True)
    records: list[FixtureRecord] = []

    for destination_index, destination in enumerate(DESTINATIONS):
        city_root = fixture_root / destination.slug
        city_root.mkdir(parents=True, exist_ok=True)
        visit_start = datetime.fromisoformat(destination.visit_start).replace(hour=9)

        for photo_index, photo in enumerate(selection[destination.slug]):
            photo_id = photo["id"]
            source_path = source_root / f"{photo_id}.jpg"
            if not source_path.exists():
                tracked_download = api_json(photo["links"]["download_location"], access_key)
                image_url = tracked_download["url"]
                separator = "&" if "?" in image_url else "?"
                image_url = f"{image_url}{separator}w=1600&fit=max&fm=jpg&q=78"
                print(f"Downloading {photo_id} for {destination.city}")
                download_file(image_url, source_path)
                time.sleep(0.15)

            for derivative_index in range(DERIVATIVES_PER_PHOTO):
                sequence = photo_index * DERIVATIVES_PER_PHOTO + derivative_index + 1
                target_path = city_root / f"{destination.slug}-{sequence:03d}-{photo_id}.jpg"
                captured_at = visit_start + timedelta(
                    hours=photo_index * 17 + derivative_index * 2,
                    minutes=(destination_index * 7 + derivative_index * 11) % 60,
                )
                latitude, longitude = deterministic_jitter(destination, photo_id, derivative_index)
                if not target_path.exists():
                    latitude, longitude, source_had_gps = write_fixture_image(
                        source_path,
                        target_path,
                        latitude,
                        longitude,
                        captured_at,
                    )
                else:
                    with Image.open(target_path) as existing_image:
                        verified = embedded_gps(existing_image)
                    if verified is None:
                        raise RuntimeError(f"Existing fixture has no GPS: {target_path}")
                    latitude, longitude = verified
                    with Image.open(source_path) as source_image:
                        source_had_gps = embedded_gps(source_image) is not None

                user = photo.get("user") or {}
                records.append(
                    FixtureRecord(
                        file=str(target_path.relative_to(output_root)),
                        unsplash_id=photo_id,
                        photographer=user.get("name") or user.get("username") or "Unknown",
                        photographer_url=(user.get("links") or {}).get("html", ""),
                        photo_url=(photo.get("links") or {}).get("html", ""),
                        city=destination.city,
                        country=destination.country,
                        latitude=round(latitude, 6),
                        longitude=round(longitude, 6),
                        captured_at=captured_at.isoformat(),
                        gps_source="embedded" if source_had_gps else "synthetic-city-jitter",
                        source_had_embedded_gps=source_had_gps,
                    )
                )

    if len(records) != EXPECTED_ASSET_COUNT:
        raise RuntimeError(f"Expected {EXPECTED_ASSET_COUNT} fixtures, built {len(records)}.")
    return records


def import_into_booted_simulator(paths: list[Path]) -> None:
    developer_dir = Path("/Applications/Xcode.app/Contents/Developer")
    environment = os.environ.copy()
    environment["DEVELOPER_DIR"] = str(developer_dir)

    for start in range(0, len(paths), 40):
        batch = paths[start : start + 40]
        command = ["xcrun", "simctl", "addmedia", "booted", *(str(path) for path in batch)]
        subprocess.run(command, check=True, env=environment)
        print(f"Imported {min(start + len(batch), len(paths))}/{len(paths)} simulator assets")


def main() -> int:
    arguments = parse_args()
    access_key = read_env_value(arguments.env, "UNSPLASH_ACCESS_KEY")
    if not access_key:
        print(
            f"Missing UNSPLASH_ACCESS_KEY. Copy .env.unsplash.example to {arguments.env.name} "
            "and enter the Access Key locally.",
            file=sys.stderr,
        )
        return 2

    output_root = arguments.output.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    selection_path = output_root / "unsplash-selection.json"
    selection = select_photos(access_key, selection_path, arguments.refresh_selection)
    records = build_fixtures(access_key, output_root, selection)

    manifest = {
        "schemaVersion": 1,
        "generatedAt": datetime.now().astimezone().isoformat(),
        "purpose": "Local Photo Earth tvOS PhotoKit performance testing",
        "assetCount": len(records),
        "source": "Unsplash API",
        "notice": "GPS marked synthetic-city-jitter was created for testing and is not photo provenance.",
        "items": [asdict(record) for record in records],
    }
    save_json_atomic(output_root / "manifest.json", manifest)

    if arguments.import_simulator:
        import_into_booted_simulator([output_root / record.file for record in records])

    synthetic_count = sum(record.gps_source == "synthetic-city-jitter" for record in records)
    print(f"Ready: {len(records)} JPEGs across {len(DESTINATIONS)} destinations")
    print(f"Synthetic GPS: {synthetic_count}; retained embedded GPS: {len(records) - synthetic_count}")
    print(f"Manifest: {output_root / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
