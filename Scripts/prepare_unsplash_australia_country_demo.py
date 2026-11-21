#!/usr/bin/env python3
"""Extend the unique Photo Earth promo library with four Australian cities.

The existing 500-photo fixture remains unchanged. This script builds a separate
600-photo library by hard-linking those 500 JPEGs and adding 25 distinct
Unsplash photos for Melbourne, Brisbane, Perth and Adelaide. Together with the
existing 50 Sydney photos, Australia contains five cities and 150 photos.

Dates and city-level GPS coordinates are fictional metadata for exercising
Photo Earth's country/city aggregation. They are not source-photo provenance.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont, ImageOps


PROJECT_ROOT = Path(__file__).resolve().parents[1]
BASE_ROOT = PROJECT_ROOT / ".local-test-data" / "unsplash-unique-500"
OUTPUT_ROOT = PROJECT_ROOT / ".local-test-data" / "unsplash-australia-600"
ENV_PATH = PROJECT_ROOT / ".env.unsplash.local"
TARGET_PER_NEW_CITY = 25
PEOPLE_TARGET_PER_NEW_CITY = 3
DOWNLOAD_WIDTH = 2400
MAX_WORKERS = 4
EXCLUDED_PHOTO_IDS: set[str] = set()
SELECTION_POLICY_VERSION = "2"


def load_module(name: str, path: Path) -> Any:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load helper module from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


FIXTURE = load_module(
    "photoearth_fixture_helpers_australia",
    PROJECT_ROOT / "Scripts" / "prepare_unsplash_simulator_library.py",
)
UNIQUE = load_module(
    "photoearth_unique_helpers_australia",
    PROJECT_ROOT / "Scripts" / "prepare_unsplash_unique_500.py",
)

NEW_DESTINATIONS = (
    FIXTURE.Destination(
        "melbourne",
        "Melbourne Australia travel architecture skyline",
        "Melbourne",
        "Australia",
        -37.8136,
        144.9631,
        "2025-11-03",
    ),
    FIXTURE.Destination(
        "brisbane",
        "Brisbane Australia travel river skyline",
        "Brisbane",
        "Australia",
        -27.4698,
        153.0251,
        "2025-09-08",
    ),
    FIXTURE.Destination(
        "perth",
        "Perth Western Australia travel city coast",
        "Perth",
        "Australia",
        -31.9523,
        115.8613,
        "2025-06-14",
    ),
    FIXTURE.Destination(
        "adelaide",
        "Adelaide South Australia travel city architecture",
        "Adelaide",
        "Australia",
        -34.9285,
        138.6007,
        "2025-03-22",
    ),
)
DESTINATIONS = {destination.slug: destination for destination in NEW_DESTINATIONS}
EXTRA_QUERIES = {
    "melbourne": (
        "Melbourne Australia",
        "Melbourne skyline Australia",
        "Melbourne street Australia",
        "Melbourne architecture",
    ),
    "brisbane": (
        "Brisbane Australia",
        "Brisbane river Australia",
        "Brisbane skyline",
        "Brisbane Queensland",
    ),
    "perth": (
        "Perth Western Australia",
        "Perth Australia city",
        "Perth Australia beach",
        "Perth skyline Australia",
    ),
    "adelaide": (
        "Adelaide South Australia",
        "Adelaide Australia city",
        "Adelaide architecture Australia",
        "Adelaide skyline",
    ),
}
VARIETY_QUERIES = {
    "melbourne": (
        "Melbourne street art Australia",
        "Melbourne cafe laneway",
        "St Kilda Melbourne beach",
        "Melbourne architecture details",
    ),
    "brisbane": (
        "Brisbane South Bank",
        "Brisbane street Australia",
        "Brisbane park Australia",
        "Brisbane people city",
    ),
    "perth": (
        "Perth Kings Park",
        "Perth beach Australia",
        "Perth street Australia",
        "Perth architecture",
    ),
    "adelaide": (
        "Adelaide Central Market",
        "Adelaide Botanic Garden",
        "Glenelg Adelaide beach",
        "Adelaide Hills Australia",
    ),
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT_ROOT)
    parser.add_argument("--skip-tracking", action="store_true")
    parser.add_argument("--tracking-only", action="store_true")
    parser.add_argument("--tracking-batch", action="store_true")
    return parser.parse_args()


def save_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def search_url(query: str, page: int) -> str:
    return UNIQUE.search_url(query, page)


def discover(output_root: Path, access_key: str) -> dict[str, Any]:
    cache_path = output_root / "search-candidates.json"
    cache = json.loads(cache_path.read_text(encoding="utf-8")) if cache_path.exists() else {}
    requests: list[tuple[str, str, int]] = []
    for destination in NEW_DESTINATIONS:
        people_query = (
            f"{destination.city} Australia people travel walking friends crowd street beach"
        )
        requests.extend(
            [
                (f"{destination.slug}:travel:1", destination.query, 1),
                (f"{destination.slug}:travel:2", destination.query, 2),
                (f"{destination.slug}:people:1", people_query, 1),
            ]
        )
        requests.extend(
            (f"{destination.slug}:broad:{index}", query, 1)
            for index, query in enumerate(EXTRA_QUERIES[destination.slug], 1)
        )
        requests.extend(
            (f"{destination.slug}:variety:{index}", query, 1)
            for index, query in enumerate(VARIETY_QUERIES[destination.slug], 1)
        )

    for index, (slot, query, page) in enumerate(requests, 1):
        if slot in cache:
            print(f"Discovery cached {index:02d}/{len(requests)} {slot}", flush=True)
            continue
        payload, headers = UNIQUE.api_request_json(search_url(query, page), access_key)
        cache[slot] = {"query": query, "page": page, "results": payload.get("results", [])}
        save_json(cache_path, cache)
        print(
            f"Discovered {index:02d}/{len(requests)} {slot}; "
            f"results={len(cache[slot]['results'])}; remaining={headers.get('x-ratelimit-remaining')}",
            flush=True,
        )
        time.sleep(0.15)
    return cache


def usable(photo: dict[str, Any]) -> bool:
    return bool(
        photo.get("id")
        and photo["id"] not in EXCLUDED_PHOTO_IDS
        and (photo.get("urls") or {}).get("raw")
        and (photo.get("links") or {}).get("download_location")
        and int(photo.get("width") or 0) >= DOWNLOAD_WIDTH
        and int(photo.get("width") or 0) > int(photo.get("height") or 0)
    )


def select_addition(output_root: Path, candidates: dict[str, Any]) -> list[dict[str, Any]]:
    selection_path = output_root / "selection.json"
    policy_path = output_root / "selection-policy-version.txt"
    base_manifest = json.loads((BASE_ROOT / "manifest.json").read_text(encoding="utf-8"))
    base_ids = {record["unsplash_id"] for record in base_manifest["items"]}
    if selection_path.exists():
        selection = json.loads(selection_path.read_text(encoding="utf-8"))
        ids = {item["photo"]["id"] for item in selection}
        if (
            len(selection) == 100
            and len(ids) == 100
            and ids.isdisjoint(base_ids)
            and ids.isdisjoint(EXCLUDED_PHOTO_IDS)
            and policy_path.exists()
            and policy_path.read_text(encoding="utf-8").strip() == SELECTION_POLICY_VERSION
        ):
            return selection
        print("Cached Australia selection is stale; rebuilding", flush=True)

    used_ids = set(base_ids)
    selection: list[dict[str, Any]] = []
    for destination in NEW_DESTINATIONS:
        city_items: list[dict[str, Any]] = []
        people = [
            photo
            for photo in candidates[f"{destination.slug}:people:1"]["results"]
            if usable(photo)
        ]
        ranked_people = sorted(
            enumerate(people),
            key=lambda pair: UNIQUE.people_safety_score(pair[1], pair[0]),
            reverse=True,
        )
        for _, photo in ranked_people:
            if len(city_items) >= PEOPLE_TARGET_PER_NEW_CITY:
                break
            if photo["id"] in used_ids:
                continue
            city_items.append(
                {
                    "destination": destination.slug,
                    "category": "people",
                    "photo": photo,
                    "alreadyTracked": False,
                }
            )
            used_ids.add(photo["id"])

        pool_keys = [f"{destination.slug}:travel:1"]
        pool_keys.extend(
            f"{destination.slug}:variety:{index}"
            for index in range(1, len(VARIETY_QUERIES[destination.slug]) + 1)
        )
        pool_keys.extend(
            f"{destination.slug}:broad:{index}"
            for index in range(1, len(EXTRA_QUERIES[destination.slug]) + 1)
        )
        pool_keys.append(f"{destination.slug}:travel:2")
        pools = [list(candidates[key]["results"]) for key in pool_keys]
        pool_positions = [0] * len(pools)
        while len(city_items) < TARGET_PER_NEW_CITY:
            added_this_round = False
            for pool_index, pool in enumerate(pools):
                while pool_positions[pool_index] < len(pool):
                    photo = pool[pool_positions[pool_index]]
                    pool_positions[pool_index] += 1
                    if not usable(photo) or photo["id"] in used_ids:
                        continue
                    city_items.append(
                        {
                            "destination": destination.slug,
                            "category": "travel",
                            "photo": photo,
                            "alreadyTracked": False,
                        }
                    )
                    used_ids.add(photo["id"])
                    added_this_round = True
                    break
                if len(city_items) >= TARGET_PER_NEW_CITY:
                    break
            if not added_this_round:
                break

        if len(city_items) != TARGET_PER_NEW_CITY:
            raise RuntimeError(
                f"{destination.city}: selected {len(city_items)}, expected {TARGET_PER_NEW_CITY}"
            )
        print(
            f"Selected {len(city_items)} unique photos for {destination.city} "
            f"({sum(item['category'] == 'people' for item in city_items)} people-oriented)",
            flush=True,
        )
        selection.extend(city_items)

    if len(selection) != 100 or len({item["photo"]["id"] for item in selection}) != 100:
        raise RuntimeError("Australia addition is not exactly 100 unique Unsplash IDs")
    save_json(selection_path, selection)
    policy_path.write_text(SELECTION_POLICY_VERSION + "\n", encoding="utf-8")
    return selection


def hardlink_base_library(output_root: Path) -> list[dict[str, Any]]:
    manifest = json.loads((BASE_ROOT / "manifest.json").read_text(encoding="utf-8"))
    records = manifest["items"]
    if len(records) != 500:
        raise RuntimeError("Base fixture must contain exactly 500 records")
    for record in records:
        source = BASE_ROOT / record["file"]
        target = output_root / record["file"]
        target.parent.mkdir(parents=True, exist_ok=True)
        if target.exists() and os.path.samefile(source, target):
            continue
        temporary = target.with_suffix(target.suffix + ".partial")
        temporary.unlink(missing_ok=True)
        try:
            os.link(source, temporary)
        except OSError:
            with source.open("rb") as source_stream, temporary.open("wb") as target_stream:
                while chunk := source_stream.read(1024 * 1024):
                    target_stream.write(chunk)
        temporary.replace(target)
    return [dict(record) for record in records]


def coordinate(destination: Any, photo_id: str) -> tuple[float, float]:
    digest = hashlib.sha256(f"australia-600:{destination.slug}:{photo_id}".encode()).digest()
    latitude_fraction = int.from_bytes(digest[:4], "big") / 0xFFFFFFFF
    longitude_fraction = int.from_bytes(digest[4:8], "big") / 0xFFFFFFFF
    return (
        destination.latitude + (latitude_fraction - 0.5) * 0.018,
        destination.longitude + (longitude_fraction - 0.5) * 0.022,
    )


def prepare_one(output_root: Path, item: dict[str, Any], photo_index: int) -> dict[str, Any]:
    destination = DESTINATIONS[item["destination"]]
    photo = item["photo"]
    target = output_root / "photos" / destination.slug / f"{photo_index + 1:03d}-{photo['id']}.jpg"
    target.parent.mkdir(parents=True, exist_ok=True)
    captured_at = datetime.fromisoformat(destination.visit_start).replace(hour=8, minute=20)
    captured_at += timedelta(hours=photo_index * 4, minutes=(photo_index * 13) % 60)
    latitude, longitude = coordinate(destination, photo["id"])

    valid_existing = False
    if target.exists():
        try:
            with Image.open(target) as existing:
                existing.verify()
            with Image.open(target) as existing:
                embedded = FIXTURE.embedded_gps(existing)
                valid_existing = existing.width >= DOWNLOAD_WIDTH and embedded is not None
                if embedded is not None:
                    latitude, longitude = embedded
        except (OSError, ValueError):
            valid_existing = False
    if not valid_existing:
        target.unlink(missing_ok=True)
        last_error: Exception | None = None
        for attempt in range(1, 6):
            with tempfile.TemporaryDirectory(prefix="photoearth-australia-") as temporary:
                source_path = Path(temporary) / f"{photo['id']}.jpg"
                try:
                    FIXTURE.download_file(UNIQUE.sized_url(photo["urls"]["raw"]), source_path)
                    with Image.open(source_path) as source:
                        source.verify()
                    latitude, longitude, _ = FIXTURE.write_fixture_image(
                        source_path, target, latitude, longitude, captured_at
                    )
                    last_error = None
                    break
                except (OSError, ValueError) as error:
                    last_error = error
                    target.unlink(missing_ok=True)
                    print(
                        f"Invalid image payload for {photo['id']}; retrying ({attempt}/5)",
                        flush=True,
                    )
            if attempt < 5:
                time.sleep(2**attempt)
        if last_error is not None:
            raise RuntimeError(f"Could not decode {photo['id']} after 5 downloads") from last_error

    user = photo.get("user") or {}
    return {
        "file": str(target.relative_to(output_root)),
        "unsplash_id": photo["id"],
        "category": item["category"],
        "photographer": user.get("name") or user.get("username") or "Unknown",
        "photographer_url": (user.get("links") or {}).get("html", ""),
        "photo_url": (photo.get("links") or {}).get("html", ""),
        "description": UNIQUE.description(photo),
        "city": destination.city,
        "country": destination.country,
        "latitude": round(latitude, 6),
        "longitude": round(longitude, 6),
        "captured_at": captured_at.isoformat(),
        "gps_source": "synthetic-city-jitter",
        "source_had_embedded_gps": False,
    }


def prepare_addition(output_root: Path, selection: list[dict[str, Any]]) -> list[dict[str, Any]]:
    indexed: list[tuple[dict[str, Any], int]] = []
    counts = {destination.slug: 0 for destination in NEW_DESTINATIONS}
    for item in selection:
        index = counts[item["destination"]]
        counts[item["destination"]] += 1
        indexed.append((item, index))

    records: list[dict[str, Any]] = []
    errors: list[BaseException] = []
    completed = 0
    lock = threading.Lock()
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_WORKERS) as executor:
        futures = [
            executor.submit(prepare_one, output_root, item, index) for item, index in indexed
        ]
        for future in concurrent.futures.as_completed(futures):
            try:
                records.append(future.result())
            except BaseException as error:
                errors.append(error)
                print(f"Worker failed: {error}", flush=True)
            with lock:
                completed += 1
                if completed % 10 == 0 or completed == len(futures):
                    print(f"Prepared Australia addition {completed}/{len(futures)}", flush=True)
    if errors:
        raise RuntimeError(f"{len(errors)} image workers failed; rerun to resume") from errors[0]
    records.sort(key=lambda record: (record["city"], record["captured_at"], record["unsplash_id"]))
    return records


def archive_stale_photos(output_root: Path, records: list[dict[str, Any]]) -> int:
    """Move JPEGs left by an older selection out of the active fixture tree."""
    photos_root = output_root / "photos"
    expected = {Path(record["file"]) for record in records}
    stale = [
        path
        for path in photos_root.glob("*/*.jpg")
        if path.relative_to(output_root) not in expected
    ]
    if not stale:
        return 0

    archive_root = (
        output_root.parent
        / f"{output_root.name}-discarded-selections"
        / datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    )
    for source in stale:
        destination = archive_root / source.relative_to(photos_root)
        destination.parent.mkdir(parents=True, exist_ok=True)
        source.replace(destination)
    print(
        f"Archived {len(stale)} stale JPEGs from an older selection to {archive_root}",
        flush=True,
    )
    return len(stale)


def contact_sheets(output_root: Path, records: list[dict[str, Any]], folder: str) -> None:
    root = output_root / folder
    root.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 17)
    small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
    for old in root.glob("contact-sheet-*.jpg"):
        old.unlink()
    for page_start in range(0, len(records), 25):
        page = records[page_start : page_start + 25]
        sheet = Image.new("RGB", (1800, 1225), (14, 15, 19))
        draw = ImageDraw.Draw(sheet)
        for offset, record in enumerate(page):
            with Image.open(output_root / record["file"]) as source:
                thumb = ImageOps.fit(source.convert("RGB"), (340, 180), Image.Resampling.LANCZOS)
            x = (offset % 5) * 360 + 10
            y = (offset // 5) * 245 + 10
            sheet.paste(thumb, (x, y))
            number = page_start + offset + 1
            draw.rectangle((x, y, x + 45, y + 27), fill=(0, 0, 0))
            draw.text((x + 6, y + 3), str(number), fill="white", font=font)
            draw.text(
                (x, y + 188),
                f"{record['city']} · {record['category']}",
                fill=(238, 240, 246),
                font=font,
            )
            draw.text((x, y + 214), record["unsplash_id"], fill=(160, 168, 184), font=small)
        sheet.save(root / f"contact-sheet-{page_start // 25 + 1:02d}.jpg", quality=90)


def write_artifacts(output_root: Path, records: list[dict[str, Any]]) -> None:
    records.sort(key=lambda record: (record["country"], record["city"], record["captured_at"]))
    manifest = {
        "schemaVersion": 1,
        "generatedAt": datetime.now().astimezone().isoformat(),
        "purpose": "Photo Earth App Store demo with an Australia multi-city country collection",
        "assetCount": 600,
        "uniqueUnsplashPhotoCount": 600,
        "derivativeCopiesPerPhoto": 1,
        "source": "Unsplash API",
        "licenseURL": "https://unsplash.com/license",
        "notice": "All dates and city-level GPS coordinates are fictional demo metadata, not photo provenance.",
        "items": records,
    }
    save_json(output_root / "manifest.json", manifest)

    australia = [record for record in records if record["country"] == "Australia"]
    city_counts = {
        city: sum(record["city"] == city for record in australia)
        for city in sorted({record["city"] for record in australia})
    }
    summary = {
        "country": "Australia",
        "photoCount": len(australia),
        "cityCount": len(city_counts),
        "cities": city_counts,
        "expectedAppAggregation": "Australia country collection containing five city collections",
    }
    save_json(output_root / "country-summary.json", summary)

    credits = [
        "# Photo Earth Australia 600-photo fixture credits",
        "",
        "Every JPEG uses a distinct Unsplash photo ID. Dates and GPS are fictional demo metadata.",
        "",
        "| Destination | Category | Photographer | Source photo |",
        "|---|---|---|---|",
    ]
    for record in records:
        credits.append(
            f"| {record['city']}, {record['country']} | {record['category']} | "
            f"[{record['photographer']}]({record['photographer_url']}) | "
            f"[{record['unsplash_id']}]({record['photo_url']}) |"
        )
    credits.extend(
        [
            "",
            "- [Unsplash License](https://unsplash.com/license)",
            "- [Unsplash releases and trademarks guidance](https://help.unsplash.com/en/articles/2612329-releases-and-trademarks)",
            "",
        ]
    )
    (output_root / "CREDITS.md").write_text("\n".join(credits), encoding="utf-8")

    contact_sheets(output_root, records, "contact-sheets")
    contact_sheets(output_root, australia, "australia-contact-sheets")
    (output_root / "BUILD_READY").write_text(
        datetime.now().astimezone().isoformat() + "\n", encoding="utf-8"
    )


def main() -> int:
    arguments = parse_args()
    output_root = arguments.output.resolve()
    output_root.mkdir(parents=True, exist_ok=True)
    access_key = FIXTURE.read_env_value(ENV_PATH, "UNSPLASH_ACCESS_KEY")
    if not access_key:
        print(f"Missing UNSPLASH_ACCESS_KEY in {ENV_PATH}", file=sys.stderr)
        return 2

    if arguments.tracking_only or arguments.tracking_batch:
        selection = json.loads((output_root / "selection.json").read_text(encoding="utf-8"))
        UNIQUE.drain_tracking_queue(
            output_root,
            selection,
            access_key,
            wait_for_quota=not arguments.tracking_batch,
        )
        return 0

    candidates = discover(output_root, access_key)
    selection = select_addition(output_root, candidates)
    records = hardlink_base_library(output_root)
    records.extend(prepare_addition(output_root, selection))
    if len(records) != 600 or len({record["unsplash_id"] for record in records}) != 600:
        raise RuntimeError("Combined library is not exactly 600 unique Unsplash photos")
    archive_stale_photos(output_root, records)
    write_artifacts(output_root, records)
    print(
        f"BUILD READY: {output_root} contains 600 unique JPEGs; "
        "Australia contains 150 photos across five cities",
        flush=True,
    )
    if not arguments.skip_tracking:
        UNIQUE.drain_tracking_queue(output_root, selection, access_key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
