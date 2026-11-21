"""Replay the public city benchmark through Photo Earth's production SQLite matcher."""

import argparse
import csv
import gzip
import sqlite3
import subprocess
import tempfile
import unicodedata
from collections import Counter, defaultdict
from pathlib import Path

from city_parent_expectations import PARENTS, public_baseline, read_parents

ROOT = Path(__file__).resolve().parents[1]
GEOCODING = ROOT / "PhotoEarth/Services/Geocoding"
SAMPLES = ROOT / "Docs/WORLD_CITY_PUBLIC_COORDINATE_RESULTS_2026-11-20.csv"
ATLAS = ROOT / "PhotoEarth/Resources/WorldCityAtlas.sqlite"

# The standalone Mac executable needs only the two value types shared with the tvOS app.
HARNESS = r"""
import Foundation

struct GeoCoordinate: Sendable {
    let latitude: Double
    let longitude: Double
    var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}
struct PlaceDisplayLabel: Sendable {
    let city: String
    let country: String?
    var regionCode: String? = nil
    var source: String? = nil
    var sourceVersion: String? = nil
    var offlinePlaceID: String? = nil
}
@main struct Probe {
    static func main() throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[1])
        guard let atlas = WorldCityAtlas(url: url) else { throw CocoaError(.fileReadCorruptFile) }
        let catalog = JourneyPlaceCatalog(atlas: atlas)
        let locale = Locale(identifier: "en")
        let languages = ["en","de","es","fr","it","ja","zh-Hans","zh-Hant","zh-Hans-TW","zh-Hant-CN","zh-Hant-HK","zh-Hant-MO","zh-Hant-TW"]
        var titles = [String: [String: String]]()
        while let line = readLine() {
            let fields = line.split(separator: "\t")
            guard (2...3).contains(fields.count), let latitude = Double(fields[0]),
                  let longitude = Double(fields[1]) else { throw CocoaError(.fileReadCorruptFile) }
            let point = GeoCoordinate(latitude: latitude, longitude: longitude)
            let label = try catalog.label(point, locale: locale)
            if CommandLine.arguments.contains("--languages") {
                let historical = fields.count == 3 ? "catalog:" + String(fields[2]) : nil
                let historicalTitles = historical.map { catalog.shelfTitles(for: [$0], languages: languages)[$0] ?? [:] }
                for lang in languages {
                    let displayLocale = Locale(identifier: lang)
                    let other = try catalog.label(point, locale: displayLocale)
                    if let historicalTitles {
                        precondition(historicalTitles[lang] == other.city, "Saved subdivision and current city disagree for " + lang)
                    }
                    if let region = other.regionCode, !region.isEmpty {
                        let expected = JourneyRegionNames.name(code: region, locale: displayLocale)
                        precondition(other.country == expected && expected != region && expected?.isEmpty == false,
                            "Invalid country display name at a public point for " + lang)
                    }
                    if let id = other.offlinePlaceID {
                        if let previous = titles[id]?[lang] { precondition(other.city == previous) }
                        titles[id, default: [:]][lang] = other.city
                    }
                    guard other.offlinePlaceID == label.offlinePlaceID, other.regionCode == label.regionCode,
                          other.city.isEmpty == label.city.isEmpty, other.country?.isEmpty == label.country?.isEmpty else {
                        preconditionFailure("Locale changed identity or label availability at public point \(point) in \(lang)")
                    }
                }
            }
            print([label.regionCode ?? "", label.city, label.offlinePlaceID ?? ""].joined(separator: "\t"))
        }
        if !titles.isEmpty {
            let shelf = catalog.shelfTitles(for: Set(titles.keys), languages: languages)
            for (id, expected) in titles {
                for (language, name) in expected {
                    precondition(shelf[id]?[language] == name, "Top Shelf disagrees for " + id + " in " + language)
                }
            }
            let cannes = "catalog:gn:3028808"
            precondition(shelf[cannes]?["zh-Hans-TW"] == "戛纳" && shelf[cannes]?["zh-Hant"] == "坎城"
                && shelf[cannes]?["zh-Hant-HK"] == "康城")
            precondition(shelf["catalog:gn:3515040"]?["ja"] == "トゥルム")
            precondition(shelf["catalog:1159151497"]?["zh-Hant"] == "杜拜")
        }
    }
}
"""


def normalized(name):
    return "".join(c for c in unicodedata.normalize("NFKD", name.casefold()) if c.isalnum())


def grade(sample, region, name):
    if not region:
        return "unknown"
    if region != sample["expected_region"]:
        return "wrong_country"
    if not name:
        return "country_only"
    aliases = {normalized(x) for x in sample["accepted_city_names"].split("|")}
    return "right" if normalized(name) in aliases else "wrong_city"


def export_priority_languages(points_by_region, matched_regions, audit, output):
    languages = ("en", "de", "es", "fr", "it", "ja", "zh-Hans", "zh-Hant",
                 "zh-Hant-HK", "zh-Hant-MO", "zh-Hant-TW")
    attested = defaultdict(set)
    with gzip.open(audit, "rt", encoding="utf-8") as stream:
        for row in csv.DictReader(stream):
            key = row["place_id"]
            if key in matched_regions and key == row["display_id"] and row["exact_target_refs"]:
                attested[key].add(row["locale"])
    counts = defaultdict(Counter)
    for key, regions in matched_regions.items():
        for region in regions:
            current = counts[region]
            current["points_matching_city"] += 1
            current["all_eight_attested"] += all(lang in attested[key] for lang in languages[:8])
            current.update(attested[key].intersection(languages))
    fields = ("points_matching_city", "all_eight_attested", *languages)
    with output.open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("reference_region", "reference_points", *fields))
        for region, total in sorted(points_by_region.items()):
            writer.writerow((region, total, *(counts[region][field] for field in fields)))


def check_priority(binary, atlas, gazetteer, parents, baseline, language_audit=None, output=None, point_output=None):
    with SAMPLES.with_name("WORLD_CITY_PRIORITY_DESTINATIONS_2026-11-20.csv").open() as stream:
        cities = list(csv.DictReader(stream))
    wanted = {city["geonames_id"] for city in cities}
    aliases = {}
    with gazetteer.open() as stream:
        for line in stream:
            row = line.rstrip("\n").split("\t")
            if row[0] in wanted:
                aliases[row[0]] = {normalized(n) for n in [row[1], row[2], *row[3].split(",")] if n}
    if aliases.keys() != wanted:
        raise ValueError("Use the GeoNames cities15000 snapshot containing the frozen priority sample")
    data = "".join(f"{row['latitude']}\t{row['longitude']}\n" for row in cities)
    result = subprocess.run([binary, atlas], input=data, text=True, capture_output=True, check=True)
    lines = result.stdout.splitlines()
    if len(lines) != len(cities):
        raise ValueError("Incomplete priority sample")
    counts = Counter()
    strict_counts = Counter()
    prior_aware_counts = Counter()
    lost = gained = 0
    prior_losses = prior_gains = 0
    matched_regions = defaultdict(list)
    results = []
    with sqlite3.connect(atlas.resolve().as_uri() + "?mode=ro", uri=True) as db:
        for row, line in zip(cities, lines):
            region, display_name, key = line.split("\t")
            names = db.execute(
                "SELECT p.names, e.name FROM place p LEFT JOIN preferred e ON e.id=p.id AND e.locale='en' "
                "WHERE p.id=?", (key.removeprefix("catalog:"),)
            ).fetchone()
            if key:
                if not names:
                    raise ValueError(f"The matcher returned an unknown city ID: {key}")
                original, english, *_ = names[0].split("\t")
                if display_name != (names[1] or english or original):
                    raise ValueError(f"The displayed English name differs from the city record for {key}")
            matches = names and any(normalized(n) in aliases[row["geonames_id"]] for n in names[0].split("\t") if n)
            grade = "different_region" if region != row["region"] else "right" if matches else "different_city"
            strict_counts[grade] += 1
            old = baseline["priority", row["geonames_id"], row["latitude"], row["longitude"]]
            candidates = ["gn:" + row["geonames_id"]]
            if old["region"] == row["region"] and old["priority_strict_grade"] == "right":
                candidates.append(old["id"].removeprefix("catalog:"))
            reviewed = any(parents.get(child) == (key.removeprefix("catalog:"), region) for child in candidates)
            aware = "right" if grade == "different_city" and region == row["region"] and reviewed else grade
            counts[aware] += 1
            prior_grade = old["priority_strict_grade"]
            if prior_grade == "different_city" and parents.get("gn:" + row["geonames_id"]) == (old["id"].removeprefix("catalog:"), row["region"]):
                prior_grade = "right"
            prior_aware_counts[prior_grade] += 1
            prior_losses += prior_grade == "right" and aware != "right"
            prior_gains += prior_grade != "right" and aware == "right"
            if point_output:
                results.append((row["geonames_id"], row["region"], row["reference_name"], row["latitude"],
                                row["longitude"], key, region, display_name, grade, aware, old["id"], old["city"], old["priority_strict_grade"], prior_grade))
            if language_audit and aware == "right":
                matched_regions[key.removeprefix("catalog:")].append(region)
            previously_correct = row["current_grade"] == "right"
            lost += previously_correct and aware != "right"
            gained += not previously_correct and aware == "right"
    if point_output:
        open_table = gzip.open if point_output.suffix == ".gz" else open
        with open_table(point_output, "wt", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("geonames_id", "reference_region", "reference_city", "latitude", "longitude",
                             "result_id", "result_region", "result_city", "strict_grade", "city_grade", "prior_id", "prior_city", "prior_strict_grade", "prior_city_grade"))
            writer.writerows(results)
    if language_audit:
        export_priority_languages(Counter(city["region"] for city in cities), matched_regions, language_audit, output)
    print("Priority destinations", len(cities), "strict", dict(strict_counts), "city-level", dict(counts), f"{gained} newly matching, {lost} no longer matching")
    print("Release .4 with the same city-level rules", dict(prior_aware_counts),
          f"{prior_gains} newly matching in this release, {prior_losses} regressions")
    if counts["right"] < 2075 or counts["different_region"] > 3 or lost > 1 or prior_losses:
        raise SystemExit("The priority-destination sample regressed against its historical release gates")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--atlas", type=Path, default=ATLAS)
    parser.add_argument("--check-release", action="store_true", help="check eight languages, include fresh landmarks and enforce release thresholds")
    parser.add_argument("--priority-gazetteer", type=Path, help="also compare the 2,177 frozen reference points using cities15000.txt aliases")
    parser.add_argument("--language-audit", type=Path, help="published per-place/locale CSV.gz")
    parser.add_argument("--priority-language-output", type=Path, help="write evidence coverage by priority country")
    parser.add_argument("--priority-point-output", type=Path, help="write actual labels for the priority city benchmark")
    parser.add_argument("--city-parents", type=Path, default=PARENTS, help="reviewed parent relationships from the source checkout")
    parser.add_argument("--strict-migration", action="store_true", help="replay the original .4 public gates without city reclassification")
    args = parser.parse_args()
    parents = {} if args.strict_migration else read_parents(args.city_parents)
    baseline = public_baseline()
    if args.priority_point_output and not args.priority_gazetteer:
        parser.error("--priority-point-output requires --priority-gazetteer")
    if bool(args.language_audit) != bool(args.priority_language_output) or (args.language_audit and not args.priority_gazetteer):
        parser.error("The language audit and output must be supplied together with --priority-gazetteer")
    if args.priority_gazetteer and not args.check_release:
        parser.error("--priority-gazetteer requires --check-release")
    with SAMPLES.open() as stream:
        samples = list(csv.DictReader(stream))
    if args.check_release:
        with SAMPLES.with_name("WORLD_CITY_NEW_CHECKPOINTS_2026-11-21.csv").open() as stream:
            samples.extend(csv.DictReader(stream))
        if not args.strict_migration:
            for name in ("WORLD_APPLE_CITY_CHECKPOINTS_2026-11-21.csv", "WORLD_CITY_SUBDIVISION_CHECKPOINTS_2026-11-21.csv"):
                with SAMPLES.with_name(name).open() as stream:
                    samples.extend(csv.DictReader(stream))
    coordinates = "".join("\t".join((row["latitude"], row["longitude"], row.get("legacy_id", ""))) + "\n"
                          for row in samples)
    with tempfile.TemporaryDirectory() as workspace:
        folder = Path(workspace)
        swift = folder / "Probe.swift"
        swift.write_text(HARNESS)
        binary = folder / "probe"
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(swift),
                        str(ROOT / "PhotoEarthTopShelfShared/JourneyRegionNames.swift"),
                        str(GEOCODING / "WorldCityAtlas.swift"),
                        str(GEOCODING / "JourneyPlaceCatalog.swift"), "-o", str(binary)], check=True)
        result = subprocess.run([str(binary), str(args.atlas), *(["--languages"] if args.check_release else [])], input=coordinates, text=True,
                                stdout=subprocess.PIPE, check=True)
        if args.priority_gazetteer:
            check_priority(binary, args.atlas, args.priority_gazetteer, parents, baseline,
                           args.language_audit, args.priority_language_output, args.priority_point_output)
    actual = result.stdout.splitlines()
    if len(actual) != len(samples):
        raise RuntimeError("Result count differs from public sample count")
    counts = {}
    strict_counts = {}
    changed = 0
    for row, line in zip(samples, actual):
        region, name, key = line.split("\t")
        outcome = grade(row, region, name)
        if row.get("expected_id") and key != "catalog:" + row["expected_id"]:
            outcome = "wrong_identity"
        strict_counts.setdefault(row["sample"], Counter())[outcome] += 1
        if outcome == "wrong_city" and row["sample"] not in ("apple_city", "official_subdivision", "independent_city"):
            old = baseline[row["sample"], row["source_id"], row["latitude"], row["longitude"]]
            if grade(row, old["region"], old["city"]) == "right" and parents.get(old["id"].removeprefix("catalog:")) == (key.removeprefix("catalog:"), region):
                outcome = "right"
        counts.setdefault(row["sample"], Counter())[outcome] += 1
        if not row.get("current_grade"):
            if outcome != "right":
                print(f"{row['site']} -> {region} {name} ({outcome})")
            continue
        if (region, name, outcome) != (row["current_region"], row["current_city"], row["current_grade"]):
            changed += 1
            print(f"{row['sample']} {row['source_id']} {row['site']} -> {region} {name} ({outcome})")
    for group, grades in counts.items():
        print(group, "strict", dict(strict_counts[group]), "city-level", dict(grades))
    print(f"{len(samples)} public coordinates, {changed} results changed from the audited release")
    if args.check_release:
        failed = {group: sum(grades.values()) - grades["right"] for group, grades in counts.items()
                  if grades["right"] != sum(grades.values())}
        if failed:
            raise SystemExit(f"Geographic release gate failed: {failed}")


if __name__ == "__main__":
    main()
