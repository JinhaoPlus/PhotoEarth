"""Compare both products' SQLite lookup against each other and frozen public-coordinate labels."""
import argparse
import csv
import gzip
from pathlib import Path
import subprocess
import tempfile

from city_parent_expectations import read_parents


ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "Scripts/Fixtures/WorldCityAtlas-20261121.3-labels.tsv.gz"

# Coordinates in the frozen dense sample inside MLIT N03 municipality
# boundaries 14212 (Atsugi) and 14215 (Ebina), respectively.
# https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N03-2025.html
REVIEWED_AREA_CORRECTIONS = {
    ("dense", "35.481210000000004", "139.31151"): ("JP", "gn:1865683", "gn:1864928"),
    ("dense", "35.46515", "139.4001"): ("JP", "gn:1847999", "gn:11612543"),
}

# These data carriers and the actor name are the only substitutions. The two
# production adapters and the shared reader supply every lookup and display rule.
SUPPORT = """
import Foundation
struct GeoCoordinate: Sendable {
    let latitude: Double, longitude: Double
    var isValid: Bool { (-90...90).contains(latitude) && (-180...180).contains(longitude) }
}
enum JourneyClusterer { static func isValid(_ point: GeoCoordinate) -> Bool { point.isValid } }
struct JourneyPlaceLabel: Sendable {
    let name: String
    let country: String?
    let cityIdentity: String?
    let isNearby: Bool
    let source: String
    let resolvedAt: Date
    var countryCode: String? = nil
}
struct PlaceDisplayLabel: Sendable {
    let city: String
    let country: String?
    var regionCode: String? = nil
    var source: String? = nil
    var sourceVersion: String? = nil
    var offlinePlaceID: String? = nil
}
"""

COMPARE = r"""
@main struct Compare {
    static func encoded(_ fields: [String]) throws -> String {
        String(decoding: try JSONEncoder().encode(fields), as: UTF8.self)
    }

    static func main() async throws {
        guard let tvAtlas = WorldCityAtlas(url: URL(fileURLWithPath: CommandLine.arguments[1])),
              let lensAtlas = WorldCityAtlas(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        else { throw CocoaError(.fileReadCorruptFile) }
        let tv = JourneyPlaceCatalog(atlas: tvAtlas)
        let lens = LensPinCatalog(atlas: lensAtlas)
        var counts = [String: Int]()
        var productsDiffer = 0
        var reviewedParents = 0
        var reviewedAreas = 0
        var unexpected = 0
        let header = "sample\tlatitude\tlongitude\tlocale\tregion\tplace_id\tsource\tcity\tcountry"
        guard readLine() == header else { throw CocoaError(.fileReadCorruptFile) }
        print("comparison\tsample\tlatitude\tlongitude\tlocale\texpected\tactual")
        while let line = readLine() {
            let row = line.components(separatedBy: "\t")
            guard row.count == 10, let lat = Double(row[1]), let lon = Double(row[2]) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let point = GeoCoordinate(latitude: lat, longitude: lon)
            let language = Locale(identifier: row[3])
            let a = try tv.label(point, locale: language)
            let b = try await lens.resolve(point, locale: language)
            let countryOnly = b.source == LensPinCatalog.countrySource
            let current = [a.regionCode ?? "", a.offlinePlaceID ?? "", a.source ?? "", a.city, a.country ?? ""]
            let other = [b.countryCode ?? "", b.cityIdentity ?? "", b.source,
                         countryOnly ? "" : b.name, (countryOnly ? b.name : b.country) ?? ""]
            let previous = Array(row[4...8])
            var expected = previous
            let isAreaCorrection = row[9].hasPrefix("area/")
            if !row[9].isEmpty {
                let id = isAreaCorrection ? String(row[9].dropFirst("area/".count)) : row[9]
                guard let city = tvAtlas.name(for: id, locale: language), !city.isEmpty,
                      previous[2] == JourneyPlaceCatalog.citySource else { throw CocoaError(.fileReadCorruptFile) }
                expected[1] = "catalog:" + id
                expected[3] = city
            }
            if current != other {
                productsDiffer += 1
                print((["products"] + Array(row[0...3]) + [try encoded(current), try encoded(other)]).joined(separator: "\t"))
            }
            if row[0] == "apple" {
                if current[0] != row[4] || current[1].isEmpty || current[3].isEmpty || current[2] != JourneyPlaceCatalog.citySource
                    || (row[3] == "en" && !row[7].components(separatedBy: "|").contains(current[3])) {
                    unexpected += 1
                    print((["city_checkpoint"] + Array(row[0...3]) + [row[7], try encoded(current)]).joined(separator: "\t"))
                }
            } else if current != expected {
                unexpected += 1
                print((["unexplained"] + Array(row[0...3]) + [try encoded(expected), try encoded(current)]).joined(separator: "\t"))
            } else if current != previous {
                if isAreaCorrection { reviewedAreas += 1 }
                else { reviewedParents += 1 }
                let category = isAreaCorrection ? "reviewed_city_boundary" : "reviewed_parent"
                print(([category] + Array(row[0...3]) + [try encoded(previous), try encoded(current)]).joined(separator: "\t"))
            }
            counts[row[0] + ":" + row[3], default: 0] += 1
        }
        let languages = ["en", "zh-Hans", "zh-Hant", "ja", "fr", "de", "es", "it"]
        guard languages.allSatisfy({ counts["parity:" + $0] == 1258 }),
              counts["dense:en"] == 56191 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let appleCases = languages.reduce(0) { $0 + counts["apple:" + $1, default: 0] }
        let report = "1,258 coordinates × 8 languages (10,064 cases), 56,191 dense English cases, \(appleCases) Apple city checkpoint cases; "
            + "\(productsDiffer) product differences, \(reviewedParents) reviewed parent changes, "
            + "\(reviewedAreas) reviewed city boundary changes, \(unexpected) unexplained changes.\n"
        FileHandle.standardError.write(Data(report.utf8))
        if productsDiffer != 0 || unexpected != 0 { exit(1) }
    }
}
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lenspin", type=Path, help="LensPin checkout")
    parser.add_argument("--atlas", type=Path, help="run both product adapters against a candidate SQLite database")
    parser.add_argument("--differences", type=Path, help="write every difference as TSV")
    options = parser.add_mutually_exclusive_group()
    options.add_argument("--city-parents", type=Path, help="reviewed source TSV linking child IDs to final city IDs")
    options.add_argument("--strict-migration", action="store_true", help="require the unchanged .3/.4 labels")
    args = parser.parse_args()
    parent_source = args.city_parents or args.lenspin / "Tools/journey-catalog/world-city-parents.tsv"
    parents = {} if args.strict_migration else read_parents(parent_source)
    tv_geo = ROOT / "PhotoEarth/Services/Geocoding"
    lens_geo = args.lenspin / "LensPin/Services"
    tv_db = args.atlas or ROOT / "PhotoEarth/Resources/WorldCityAtlas.sqlite"
    lens_db = args.atlas or args.lenspin / "LensPin/Resources/WorldCityAtlas.sqlite"
    regions = ROOT / "PhotoEarthTopShelfShared/JourneyRegionNames.swift"
    for first, second in ((tv_db, lens_db), (tv_geo / "WorldCityAtlas.swift", lens_geo / "WorldCityAtlas.swift"),
                          (regions, lens_geo / "JourneyRegionNames.swift")):
        if first.read_bytes() != second.read_bytes():
            raise SystemExit(f"Different product inputs: {first} and {second}")

    # Compile the actual coordinate method, without the unrelated batch visit
    # and persistence types declared later in the same application actor.
    module = (lens_geo / "JourneyPlaceResolver.swift").read_text()
    start = module.index("actor JourneyPlaceCatalog {")
    end = module.index("  struct Resolution: Sendable", start)
    actor = module[start:end].replace("actor JourneyPlaceCatalog {", "actor LensPinCatalog {", 1) + "}\n"
    with tempfile.TemporaryDirectory() as tmp:
        temp = Path(tmp)
        source = temp / "Compare.swift"
        source.write_text(SUPPORT + actor + COMPARE)
        binary = temp / "compare"
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(source), str(regions),
                        str(tv_geo / "WorldCityAtlas.swift"), str(tv_geo / "JourneyPlaceCatalog.swift"),
                        "-o", str(binary)], check=True)
        with gzip.open(FIXTURE, "rt", encoding="utf-8") as fixture:
            lines = [next(fixture)]
            seen_areas = set()
            for line in fixture:
                row = line.rstrip("\n").split("\t")
                relation = parents.get(row[5].removeprefix("catalog:"))
                if relation and relation[1] != row[4]:
                    raise ValueError(f"Historical region for {row[5]} differs from the reviewed relationship")
                expected = relation[0] if relation else ""
                key = tuple(row[:3])
                if not args.strict_migration and key in REVIEWED_AREA_CORRECTIONS:
                    region, old, city = REVIEWED_AREA_CORRECTIONS[key]
                    if expected or row[4] != region or row[5] != "catalog:" + old:
                        raise ValueError(f"Historical label differs from the reviewed boundary at {key}")
                    expected = "area/" + city
                    seen_areas.add(key)
                lines.append(line.rstrip("\n") + "\t" + expected + "\n")
            if not args.strict_migration and seen_areas != REVIEWED_AREA_CORRECTIONS.keys():
                raise ValueError("Missing reviewed city boundary points in frozen sample")
        if not args.strict_migration:
            with (ROOT / "Docs/WORLD_APPLE_CITY_CHECKPOINTS_2026-11-21.csv").open() as stream:
                checkpoints = list(csv.DictReader(stream))
            required = {"Fengjie", "Wanzhou", "Kunshan", "Yangshuo", "Dali", "Jiyuan", "Taoyuan Zhongli"}
            if not required.issubset({p["site"] for p in checkpoints}):
                raise ValueError("Missing Apple city checkpoints")
            for point in checkpoints:
                for language in ("en", "zh-Hans", "zh-Hant", "ja", "fr", "de", "es", "it"):
                    lines.append("\t".join(("apple", point["latitude"], point["longitude"], language,
                                           point["expected_region"], "", "", point["accepted_city_names"], "", "")) + "\n")
        result = subprocess.run([binary, tv_db, lens_db], input="".join(lines).encode(), capture_output=True)
        print(result.stderr.decode().strip(), flush=True)
        if args.differences:
            output = gzip.compress(result.stdout, mtime=0) if args.differences.suffix == ".gz" else result.stdout
            args.differences.write_bytes(output)
        if result.returncode:
            print("\n".join(result.stdout.decode().splitlines()[:6]))
            raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
