#!/usr/bin/env python3
"""Build a 500-photo, all-unique Unsplash library for Photo Earth promotion.

The official Unsplash API is used for discovery. Existing tracked Photo Earth
fixtures are reused, while newly selected photos are queued for the API's
``download_location`` event. With a demo API key those events are drained in
rate-limit-sized hourly batches; image files themselves can be prepared first.

Every output JPEG represents one distinct Unsplash photo ID. The script adds
fictional dates and city-level GPS jitter solely so PhotoKit can build a useful
travel demo. Those values are explicitly identified as synthetic in the
manifest and must not be treated as photo provenance.
"""

from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import http.client
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from PIL import Image, ImageDraw, ImageFont, ImageOps


PROJECT_ROOT = Path(__file__).resolve().parents[1]
ENV_PATH = PROJECT_ROOT / ".env.unsplash.local"
OUTPUT_ROOT = PROJECT_ROOT / ".local-test-data" / "unsplash-unique-500"
OLD_LIBRARY_ROOT = PROJECT_ROOT / ".local-test-data" / "unsplash-global-300"
PROMO_ADDITION_ROOT = PROJECT_ROOT / ".local-test-data" / "unsplash-promo-addition-240"
API_BASE = "https://api.unsplash.com"
USER_AGENT = "PhotoEarthUniquePromoLibrary/1.0"
TARGET_PER_DESTINATION = 50
PEOPLE_TARGET_PER_DESTINATION = 2
DOWNLOAD_WIDTH = 2400
MAX_DOWNLOAD_WORKERS = 4
# This Rio pair is the same viewpoint and frame with only a different edit.
# Keep the more natural-looking source and prevent the alternate edit from
# returning when a cached selection is rebuilt.
EXCLUDED_PHOTO_IDS = {"qUqIshTm0H0"}


def load_fixture_module() -> Any:
    path = PROJECT_ROOT / "Scripts" / "prepare_unsplash_simulator_library.py"
    spec = importlib.util.spec_from_file_location("photoearth_fixture_helpers", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Could not load fixture helpers from {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


FIXTURE = load_fixture_module()
DESTINATIONS = {destination.slug: destination for destination in FIXTURE.DESTINATIONS}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT_ROOT)
    parser.add_argument(
        "--skip-tracking",
        action="store_true",
        help="Build the library but do not drain the Unsplash download-event queue.",
    )
    parser.add_argument(
        "--tracking-only",
        action="store_true",
        help="Resume only the download-event queue for an already selected library.",
    )
    parser.add_argument(
        "--tracking-batch",
        action="store_true",
        help="Register only the events allowed by the current rate window, then exit.",
    )
    return parser.parse_args()


def save_json_atomic(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".partial")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def api_request_json(url: str, access_key: str) -> tuple[Any, dict[str, str]]:
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
            with urllib.request.urlopen(request, timeout=40) as response:
                headers = {key.lower(): value for key, value in response.headers.items()}
                return json.load(response), headers
        except urllib.error.HTTPError as error:
            if error.code in {403, 429}:
                raise
            if error.code < 500 or attempt == 4:
                detail = error.read().decode("utf-8", "replace")
                raise RuntimeError(f"Unsplash HTTP {error.code}: {detail[:400]}") from error
        except (urllib.error.URLError, http.client.IncompleteRead, json.JSONDecodeError):
            if attempt == 4:
                raise
        time.sleep(2**attempt)
    raise RuntimeError("Unsplash request retry loop ended unexpectedly")


def search_url(query: str, page: int) -> str:
    parameters = urllib.parse.urlencode(
        {
            "query": query,
            "page": page,
            "per_page": 30,
            "orientation": "landscape",
            "content_filter": "high",
        }
    )
    return f"{API_BASE}/search/photos?{parameters}"


def discover_candidates(output_root: Path, access_key: str) -> dict[str, Any]:
    path = output_root / "search-candidates.json"
    cache = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    requests: list[tuple[str, str, int]] = []
    for destination in DESTINATIONS.values():
        general = f"{destination.city} {destination.country} travel photography"
        people = f"{destination.city} {destination.country} people travel walking hiking crowd"
        requests.extend(
            [
                (f"{destination.slug}:travel:1", general, 1),
                (f"{destination.slug}:travel:2", general, 2),
                (f"{destination.slug}:people:1", people, 1),
            ]
        )

    for index, (slot, query, page) in enumerate(requests, 1):
        if slot in cache:
            print(f"Discovery cached {index:02d}/{len(requests)} {slot}", flush=True)
            continue
        payload, headers = api_request_json(search_url(query, page), access_key)
        cache[slot] = {"query": query, "page": page, "results": payload.get("results", [])}
        save_json_atomic(path, cache)
        print(
            f"Discovered {index:02d}/{len(requests)} {slot}; "
            f"results={len(cache[slot]['results'])}; remaining={headers.get('x-ratelimit-remaining')}",
            flush=True,
        )
        time.sleep(0.15)
    return cache


def existing_selections() -> dict[str, list[dict[str, Any]]]:
    selected: dict[str, list[dict[str, Any]]] = {slug: [] for slug in DESTINATIONS}
    old = json.loads((OLD_LIBRARY_ROOT / "unsplash-selection.json").read_text(encoding="utf-8"))
    for slug, photos in old.items():
        for photo in photos:
            selected[slug].append(
                {"destination": slug, "category": "travel", "photo": photo, "alreadyTracked": True}
            )

    promo = json.loads((PROMO_ADDITION_ROOT / "selected-new.json").read_text(encoding="utf-8"))
    for item in promo:
        selected[item["destination"]].append(
            {
                "destination": item["destination"],
                "category": item["category"],
                "photo": item["photo"],
                "alreadyTracked": True,
            }
        )
    return selected


def description(photo: dict[str, Any]) -> str:
    return str(photo.get("alt_description") or photo.get("description") or "")


def people_safety_score(photo: dict[str, Any], position: int) -> tuple[int, int, int]:
    text = description(photo).lower()
    group_terms = ("group", "crowd", "people", "friends", "couple", "walking", "hiking", "silhouette")
    distance_terms = ("back", "from behind", "landscape", "mountain", "street", "city", "beach", "view")
    close_terms = ("portrait", "close-up", "close up", "face", "headshot", "selfie", "posing")
    score = sum(term in text for term in group_terms) * 5
    score += sum(term in text for term in distance_terms) * 2
    score -= sum(term in text for term in close_terms) * 8
    score -= int(any(term in text for term in ("child", "kid", "girl", "boy"))) * 5
    return score, int(photo.get("likes") or 0), -position


def usable(photo: dict[str, Any]) -> bool:
    return bool(
        photo.get("id")
        and photo["id"] not in EXCLUDED_PHOTO_IDS
        and (photo.get("urls") or {}).get("raw")
        and (photo.get("links") or {}).get("download_location")
        and int(photo.get("width") or 0) >= 2000
        and int(photo.get("width") or 0) > int(photo.get("height") or 0)
    )


def select_unique_500(output_root: Path, candidates: dict[str, Any]) -> list[dict[str, Any]]:
    selection_path = output_root / "selection.json"
    if selection_path.exists():
        selection = json.loads(selection_path.read_text(encoding="utf-8"))
        if len(selection) != 500 or len({item["photo"]["id"] for item in selection}) != 500:
            raise RuntimeError("Cached selection is not exactly 500 unique Unsplash IDs")
        selected_ids = {item["photo"]["id"] for item in selection}
        if selected_ids.isdisjoint(EXCLUDED_PHOTO_IDS):
            return selection
        print("Cached selection contains a visually redundant source; rebuilding", flush=True)

    by_destination = existing_selections()
    used_ids = {item["photo"]["id"] for items in by_destination.values() for item in items}

    for slug in DESTINATIONS:
        items = by_destination[slug]
        existing_people = sum(item["category"] == "people" for item in items)
        people_needed = max(0, PEOPLE_TARGET_PER_DESTINATION - existing_people)
        people_results = [
            photo for photo in candidates[f"{slug}:people:1"]["results"] if usable(photo)
        ]
        ranked_people = sorted(
            enumerate(people_results),
            key=lambda pair: people_safety_score(pair[1], pair[0]),
            reverse=True,
        )
        for _, photo in ranked_people:
            if people_needed == 0:
                break
            if photo["id"] in used_ids:
                continue
            items.append(
                {"destination": slug, "category": "people", "photo": photo, "alreadyTracked": False}
            )
            used_ids.add(photo["id"])
            people_needed -= 1

        general_results = (
            candidates[f"{slug}:travel:1"]["results"]
            + candidates[f"{slug}:travel:2"]["results"]
            + people_results
        )
        for photo in general_results:
            if len(items) >= TARGET_PER_DESTINATION:
                break
            if not usable(photo) or photo["id"] in used_ids:
                continue
            items.append(
                {"destination": slug, "category": "travel", "photo": photo, "alreadyTracked": False}
            )
            used_ids.add(photo["id"])

        if len(items) != TARGET_PER_DESTINATION:
            raise RuntimeError(f"{slug}: selected {len(items)}, expected {TARGET_PER_DESTINATION}")
        print(
            f"Selected {len(items)} unique photos for {DESTINATIONS[slug].city} "
            f"({sum(item['category'] == 'people' for item in items)} people-oriented)",
            flush=True,
        )

    selection = [item for slug in DESTINATIONS for item in by_destination[slug]]
    if len(selection) != 500 or len({item["photo"]["id"] for item in selection}) != 500:
        raise RuntimeError("Final selection is not exactly 500 unique Unsplash IDs")
    save_json_atomic(selection_path, selection)
    return selection


def sized_url(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    query = [
        (key, value)
        for key, value in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)
        if key not in {"w", "h", "fit", "fm", "q"}
    ]
    query.extend(
        [("w", str(DOWNLOAD_WIDTH)), ("fit", "max"), ("fm", "jpg"), ("q", "86")]
    )
    return urllib.parse.urlunsplit(
        (parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), parts.fragment)
    )


def deterministic_coordinate(destination: Any, photo_id: str, index: int) -> tuple[float, float]:
    material = f"unique-500:{destination.slug}:{photo_id}:{index}".encode("utf-8")
    digest = hashlib.sha256(material).digest()
    latitude_fraction = int.from_bytes(digest[:4], "big") / 0xFFFFFFFF
    longitude_fraction = int.from_bytes(digest[4:8], "big") / 0xFFFFFFFF
    return (
        destination.latitude + (latitude_fraction - 0.5) * 0.036,
        destination.longitude + (longitude_fraction - 0.5) * 0.044,
    )


def local_source_for(photo_id: str, output_root: Path) -> Path | None:
    candidates = [
        PROMO_ADDITION_ROOT / "sources" / f"{photo_id}.jpg",
        OLD_LIBRARY_ROOT / "sources" / f"{photo_id}.jpg",
    ]
    candidates.extend((output_root / "photos").glob(f"*/*-{photo_id}.jpg"))
    for path in candidates:
        if not path.exists():
            continue
        try:
            with Image.open(path) as image:
                if image.width >= DOWNLOAD_WIDTH:
                    return path
        except OSError:
            continue
    return None


def prepare_one(
    output_root: Path,
    item: dict[str, Any],
    city_index: int,
    photo_index: int,
) -> dict[str, Any]:
    destination = DESTINATIONS[item["destination"]]
    photo = item["photo"]
    target_root = output_root / "photos" / destination.slug
    target_root.mkdir(parents=True, exist_ok=True)
    target = target_root / f"{photo_index + 1:03d}-{photo['id']}.jpg"
    captured_at = datetime.fromisoformat(destination.visit_start).replace(hour=8, minute=15)
    captured_at += timedelta(hours=photo_index * 2 + city_index * 3, minutes=(photo_index * 11) % 60)
    latitude, longitude = deterministic_coordinate(destination, photo["id"], photo_index)

    if target.exists():
        try:
            with Image.open(target) as existing:
                width = existing.width
                existing.verify()
            with Image.open(target) as existing:
                verified = FIXTURE.embedded_gps(existing)
            if verified is None or width < DOWNLOAD_WIDTH:
                target.unlink()
            else:
                latitude, longitude = verified
        except (OSError, ValueError):
            target.unlink(missing_ok=True)

    if not target.exists():
        local_source = local_source_for(photo["id"], output_root)
        if local_source is not None and local_source.stat().st_size > 0:
            with Image.open(local_source) as source:
                source.verify()
            latitude, longitude, _ = FIXTURE.write_fixture_image(
                local_source, target, latitude, longitude, captured_at
            )
        else:
            last_error: Exception | None = None
            for attempt in range(1, 6):
                with tempfile.TemporaryDirectory(prefix="photoearth-unsplash-") as temporary:
                    source_path = Path(temporary) / f"{photo['id']}.jpg"
                    try:
                        FIXTURE.download_file(sized_url(photo["urls"]["raw"]), source_path)
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
                            f"Invalid image payload for {photo['id']}; retrying "
                            f"({attempt}/5)",
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
        "description": description(photo),
        "city": destination.city,
        "country": destination.country,
        "latitude": round(latitude, 6),
        "longitude": round(longitude, 6),
        "captured_at": captured_at.isoformat(),
        "gps_source": "synthetic-city-jitter",
        "source_had_embedded_gps": False,
    }


def build_library(output_root: Path, selection: list[dict[str, Any]]) -> list[dict[str, Any]]:
    indexed: list[tuple[dict[str, Any], int, int]] = []
    city_counts = {slug: 0 for slug in DESTINATIONS}
    for item in selection:
        slug = item["destination"]
        city_index = list(DESTINATIONS).index(slug)
        photo_index = city_counts[slug]
        city_counts[slug] += 1
        indexed.append((item, city_index, photo_index))

    records: list[dict[str, Any]] = []
    errors: list[BaseException] = []
    completed = 0
    lock = threading.Lock()
    with concurrent.futures.ThreadPoolExecutor(max_workers=MAX_DOWNLOAD_WORKERS) as executor:
        futures = [
            executor.submit(prepare_one, output_root, item, city_index, photo_index)
            for item, city_index, photo_index in indexed
        ]
        for future in concurrent.futures.as_completed(futures):
            try:
                records.append(future.result())
            except BaseException as error:
                errors.append(error)
                print(f"Worker failed: {error}", flush=True)
            with lock:
                completed += 1
                if completed % 25 == 0 or completed == len(futures):
                    print(f"Prepared {completed}/{len(futures)} unique JPEGs", flush=True)

    if errors:
        raise RuntimeError(f"{len(errors)} image workers failed; rerun to resume") from errors[0]

    records.sort(key=lambda record: (record["city"], record["captured_at"], record["unsplash_id"]))
    if len(records) != 500 or len({record["unsplash_id"] for record in records}) != 500:
        raise RuntimeError("Built library is not exactly 500 unique Unsplash photos")

    expected_paths = {(output_root / record["file"]).resolve() for record in records}
    discarded_root = output_root / "discarded-from-uncurated-selection"
    for path in (output_root / "photos").glob("*/*.jpg"):
        if path.resolve() in expected_paths:
            continue
        relative = path.relative_to(output_root / "photos")
        destination = discarded_root / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        if destination.exists():
            destination.unlink()
        path.replace(destination)
    return records


def write_artifacts(output_root: Path, selection: list[dict[str, Any]], records: list[dict[str, Any]]) -> None:
    manifest = {
        "schemaVersion": 1,
        "generatedAt": datetime.now().astimezone().isoformat(),
        "purpose": "Photo Earth App Store screenshot and video demo library",
        "assetCount": 500,
        "uniqueUnsplashPhotoCount": 500,
        "derivativeCopiesPerPhoto": 1,
        "source": "Unsplash API",
        "licenseURL": "https://unsplash.com/license",
        "selectionPolicy": (
            "Landscape-oriented travel, architecture, nature and people-in-context imagery. "
            "People-oriented search candidates favor groups, crowds, backs and distant figures."
        ),
        "notice": "All dates and city-level GPS coordinates are fictional demo metadata, not photo provenance.",
        "items": records,
    }
    save_json_atomic(output_root / "manifest.json", manifest)

    credits = [
        "# Photo Earth unique 500-photo fixture credits",
        "",
        "Every JPEG in this library uses a distinct Unsplash photo ID. Dates and GPS are fictional demo metadata.",
        "",
        "| Destination | Category | Photographer | Source photo |",
        "|---|---|---|---|",
    ]
    for item in selection:
        destination = DESTINATIONS[item["destination"]]
        photo = item["photo"]
        user = photo.get("user") or {}
        photographer = user.get("name") or user.get("username") or "Unknown"
        credits.append(
            f"| {destination.city}, {destination.country} | {item['category']} | "
            f"[{photographer}]({(user.get('links') or {}).get('html', '')}) | "
            f"[{photo['id']}]({(photo.get('links') or {}).get('html', '')}) |"
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

    contact_root = output_root / "contact-sheets"
    contact_root.mkdir(parents=True, exist_ok=True)
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 17)
    small = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 13)
    for page_start in range(0, len(records), 25):
        page = records[page_start : page_start + 25]
        sheet = Image.new("RGB", (5 * 360, 5 * 245), (14, 15, 19))
        draw = ImageDraw.Draw(sheet)
        for offset, record in enumerate(page):
            path = output_root / record["file"]
            with Image.open(path) as source:
                thumb = ImageOps.fit(source.convert("RGB"), (340, 180), method=Image.Resampling.LANCZOS)
            x = (offset % 5) * 360 + 10
            y = (offset // 5) * 245 + 10
            sheet.paste(thumb, (x, y))
            number = page_start + offset + 1
            draw.rectangle((x, y, x + 45, y + 27), fill=(0, 0, 0))
            draw.text((x + 6, y + 3), str(number), fill="white", font=font)
            draw.text((x, y + 188), f"{record['city']} · {record['category']}", fill=(238, 240, 246), font=font)
            draw.text((x, y + 214), record["unsplash_id"], fill=(160, 168, 184), font=small)
        page_number = page_start // 25 + 1
        sheet.save(contact_root / f"contact-sheet-{page_number:02d}.jpg", quality=90)
    (output_root / "BUILD_READY").write_text(datetime.now().astimezone().isoformat() + "\n", encoding="utf-8")


def wait_for_next_hour() -> None:
    now = datetime.now(timezone.utc)
    next_hour = now.replace(minute=0, second=8, microsecond=0) + timedelta(hours=1)
    remaining = max(1.0, (next_hour - now).total_seconds())
    print(f"Rate limit exhausted; next tracking batch in about {int(remaining // 60) + 1} minutes", flush=True)
    while remaining > 0:
        pause = min(60.0, remaining)
        time.sleep(pause)
        remaining -= pause


def drain_tracking_queue(
    output_root: Path,
    selection: list[dict[str, Any]],
    access_key: str,
    wait_for_quota: bool = True,
) -> None:
    state_path = output_root / "tracked-downloads.json"
    tracked = json.loads(state_path.read_text(encoding="utf-8")) if state_path.exists() else {}
    queue = [item for item in selection if not item.get("alreadyTracked") and item["photo"]["id"] not in tracked]
    total_new = sum(not item.get("alreadyTracked") for item in selection)
    while queue:
        item = queue[0]
        photo = item["photo"]
        try:
            payload, headers = api_request_json(photo["links"]["download_location"], access_key)
        except urllib.error.HTTPError as error:
            if error.code in {403, 429}:
                if not wait_for_quota:
                    print("Tracking batch paused at the current Unsplash rate limit", flush=True)
                    return
                wait_for_next_hour()
                continue
            raise
        tracked[photo["id"]] = {
            "trackedAt": datetime.now().astimezone().isoformat(),
            "returnedURL": payload.get("url", ""),
        }
        save_json_atomic(state_path, tracked)
        queue.pop(0)
        completed = total_new - len(queue)
        print(
            f"Tracked new photo {completed}/{total_new}; "
            f"remainingThisHour={headers.get('x-ratelimit-remaining')}",
            flush=True,
        )
        if headers.get("x-ratelimit-remaining") == "0" and queue:
            if not wait_for_quota:
                print("Tracking batch used the current Unsplash rate window", flush=True)
                return
            wait_for_next_hour()
    (output_root / "TRACKING_COMPLETE").write_text(
        datetime.now().astimezone().isoformat() + "\n", encoding="utf-8"
    )
    print("All new Unsplash download events are registered", flush=True)


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
        drain_tracking_queue(
            output_root,
            selection,
            access_key,
            wait_for_quota=not arguments.tracking_batch,
        )
        return 0

    candidates = discover_candidates(output_root, access_key)
    selection = select_unique_500(output_root, candidates)
    records = build_library(output_root, selection)
    write_artifacts(output_root, selection, records)
    print(f"BUILD READY: {output_root} contains 500 unique geotagged JPEGs", flush=True)
    if not arguments.skip_tracking:
        drain_tracking_queue(output_root, selection, access_key)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
