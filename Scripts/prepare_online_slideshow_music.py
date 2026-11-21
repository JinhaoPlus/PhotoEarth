#!/usr/bin/env python3
"""Build the curated CC0 soundtrack and its HLS catalog for a static HTTPS host."""

import argparse
from concurrent.futures import ThreadPoolExecutor
from hashlib import sha256
import json
from pathlib import Path
import re
from shutil import copytree
import subprocess
from tempfile import TemporaryDirectory
from urllib.parse import urlsplit
from zipfile import ZipFile


SELECTION = Path(__file__).with_name("online_slideshow_music.json")
LICENSE = "https://creativecommons.org/publicdomain/zero/1.0/"
TARGET_LOUDNESS = -20
SOURCE_PEAK_LIMIT = -4


def fetch(url, cache):
    filename = Path(urlsplit(url).path).name
    destination = cache / filename
    if not destination.is_file():
        staging = destination.with_suffix(destination.suffix + ".download")
        subprocess.run([
            "curl", "--fail", "--silent", "--show-error", "--location",
            "--retry", "2", "--retry-all-errors", "--connect-timeout", "15",
            "--max-time", "240", "--output", str(staging), url,
        ], check=True)
        staging.replace(destination)
    return destination


def loudness(ffmpeg, audio):
    result = subprocess.run([
        ffmpeg, "-hide_banner", "-nostats", "-xerror", "-threads", "1", "-filter_threads", "1",
        "-i", str(audio), "-map", "0:a:0", "-af", "ebur128=peak=true:framelog=verbose",
        "-f", "null", "-",
    ], capture_output=True, encoding="utf-8", errors="replace")
    if result.returncode:
        raise RuntimeError(f"Could not decode {audio}: {result.stderr[-1500:]}")
    summary = result.stderr.rpartition("Summary:")[2]
    integrated = re.search(r"I:\s+(-?[\d.]+|-inf) LUFS", summary)
    peak = re.search(r"True peak:\s+Peak:\s+(-?[\d.]+|-inf) dBFS", summary)
    if integrated is None or peak is None:
        raise RuntimeError(f"Could not measure {audio}: {result.stderr[-1500:]}")
    return float(integrated[1]), float(peak[1])


def encode(job, ffmpeg, output):
    title, source, path, member, gain = job
    path = path.resolve()
    with TemporaryDirectory() as work_directory:
        work = Path(work_directory)
        if member is not None:
            with ZipFile(path) as archive:
                path = work / ("source" + Path(member).suffix)
                path.write_bytes(archive.read(member))
        original_digest = sha256(path.read_bytes()).digest()
        if gain is None:
            original_loudness, original_peak = loudness(ffmpeg, path)
            gain = min(TARGET_LOUDNESS - original_loudness, SOURCE_PEAK_LIMIT - original_peak, 12)

        segments = work / "hls"
        segments.mkdir()
        for _ in range(2):
            subprocess.run([
                ffmpeg, "-loglevel", "error", "-xerror", "-y", "-threads", "1", "-filter_threads", "1", "-i", str(path),
                "-map", "0:a:0", "-map_metadata", "-1", "-af", f"volume={gain:.2f}dB",
                "-c:a", "aac", "-b:a", "128k", "-f", "hls", "-hls_time", "6",
                "-hls_playlist_type", "vod", "-hls_segment_filename", "segment-%03d.ts", "index.m3u8",
            ], cwd=segments, check=True)
            integrated, peak = loudness(ffmpeg, segments / "index.m3u8")
            if peak <= -2:
                break
            # AAC can create higher peaks than the original. Allow headroom on retry.
            gain -= peak + 3

        playlist = (segments / "index.m3u8").read_text()
        duration = sum(float(value) for value in re.findall(r"#EXTINF:([\d.]+),", playlist))
        if duration < 30 or not -32 <= integrated <= -19 or not peak <= -2:
            raise ValueError(f"{title}: {duration:.1f}s, {integrated:.1f} LUFS, {peak:.1f} dBTP")

        digest = sha256()
        for asset in sorted(segments.iterdir()):
            digest.update(asset.name.encode())
            digest.update(sha256(asset.read_bytes()).digest())
        slug = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
        directory = f"{slug}-{digest.hexdigest()[:12]}"
        copytree(segments, output / "tracks" / directory, dirs_exist_ok=True)

    track = {
        "title": title, "artist": source["artist"], "stream": directory,
        "source": source["page"],
    }
    print(f"{title}: {duration:.1f}s, {integrated:.1f} LUFS, {peak:.1f} dBTP", flush=True)
    return track, original_digest


def write_playback_catalog(output, playlists, metadata):
    for playlist in playlists:
        presentation = metadata[playlist["id"]]
        titles = presentation["titles"]
        if not titles.get("en") or any(
            not isinstance(title, str) or not 1 <= len(title.strip()) <= 60 or len(title.splitlines()) != 1
            for title in titles.values()
        ):
            raise ValueError(f"Invalid localized titles for {playlist['id']}")
        if not re.fullmatch(r"[a-z0-9.]{1,64}", presentation["symbol"]):
            raise ValueError(f"Invalid icon name for {playlist['id']}")
        playlist["presentation"] = presentation

    manifest = json.dumps(
        {"version": 2, "playlists": playlists}, ensure_ascii=False, separators=(",", ":")
    )
    if len(manifest.encode()) + 1 > 65_536:
        raise ValueError("The catalog exceeds the tvOS download limit")
    pending = output / "catalog-v2.json.tmp"
    pending.write_text(manifest + "\n")
    pending.replace(output / "catalog-v2.json")


def write_catalog(output, playlists, metadata):
    credits = [
        "Photo Earth online music",
        f"License: CC0 1.0 Universal ({LICENSE})",
        "Audio was adjusted for playback loudness and transcoded to AAC.",
        "",
    ]
    playback_playlists = []
    for playlist in playlists:
        tracks = []
        for track in playlist["tracks"]:
            title, artist, source = track["title"], track["artist"], track["source"]
            credits.append(f"{title} — {artist} — {source}")
            tracks.append({"title": title, "artist": artist, "stream": track["stream"]})
        playback_playlists.append({"id": playlist["id"], "tracks": tracks})

    write_playback_catalog(output, playback_playlists, metadata)
    (output / "credits.txt").write_text("\n".join(credits) + "\n")
    (output / "_headers").write_text(
        "/catalog-v1.json\n"
        "  Cache-Control: public, max-age=300\n"
        "/catalog-v2.json\n"
        "  Cache-Control: public, max-age=300\n"
        "/tracks/*\n"
        "  Cache-Control: public, max-age=31536000, immutable\n"
        "/tracks/:track/index.m3u8\n"
        "  Content-Type: application/vnd.apple.mpegurl\n"
        "/tracks/*.ts\n"
        "  Content-Type: video/mp2t\n"
    )


def build(output, ffmpeg, cache, previous_release, workers):
    selection = json.loads(SELECTION.read_text())
    sources = selection["sources"]
    groups = selection["playlists"]
    if not 1 <= len(groups) <= 12 or any(not 2 <= len(tracks) <= 64 for tracks in groups.values()):
        raise ValueError("The catalog exceeds the tvOS playlist limits")

    (output / "tracks").mkdir(parents=True, exist_ok=True)
    if previous_release is not None:
        copytree(previous_release / "tracks", output / "tracks", dirs_exist_ok=True)
        legacy_catalog = previous_release / "catalog-v1.json"
        if legacy_catalog.is_file():
            (output / legacy_catalog.name).write_bytes(legacy_catalog.read_bytes())

    urls = {}
    for tracks in groups.values():
        for source_id, _, name, *_ in tracks:
            source = sources[source_id]
            if "archive" in source:
                urls[source_id, name] = source["archive"]
            else:
                urls[source_id, name] = source["files"] + name

    with ThreadPoolExecutor(max_workers=workers) as pool:
        unique_urls = list(dict.fromkeys(urls.values()))
        paths = dict(zip(unique_urls, pool.map(lambda url: fetch(url, cache), unique_urls)))
        jobs = []
        for tracks in groups.values():
            for source_id, title, name, *gain in tracks:
                source = sources[source_id]
                path = paths[urls[source_id, name]]
                jobs.append((
                    title, source, path, name if "archive" in source else None,
                    gain[0] if gain else None,
                ))
        results = iter(pool.map(lambda job: encode(job, ffmpeg, output), jobs))
        playlists = []
        originals = set()
        for group, tracks in groups.items():
            entries = []
            for _ in tracks:
                entry, original = next(results)
                if original in originals:
                    raise ValueError(f"Duplicate recording: {entry['title']}")
                originals.add(original)
                entries.append(entry)
            playlists.append({"id": group, "tracks": entries})

    write_catalog(output, playlists, selection["playlist_metadata"])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--metadata-only", action="store_true", help="Refresh titles and icons in a staged v2 catalog")
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--source-directory", type=Path, help="Reuse and cache original downloads here")
    parser.add_argument("--previous-release", type=Path, help="Keep previously published HLS URLs working")
    parser.add_argument("--workers", type=int, default=4)
    arguments = parser.parse_args()
    if arguments.metadata_only:
        manifest = json.loads((arguments.output / "catalog-v2.json").read_text())
        if manifest["version"] != 2:
            raise ValueError("A staged v2 catalog is required")
        metadata = json.loads(SELECTION.read_text())["playlist_metadata"]
        write_playback_catalog(arguments.output, manifest["playlists"], metadata)
    else:
        with TemporaryDirectory() as temporary_cache:
            cache = (arguments.source_directory or Path(temporary_cache)).resolve()
            cache.mkdir(parents=True, exist_ok=True)
            build(arguments.output, arguments.ffmpeg, cache, arguments.previous_release, arguments.workers)
