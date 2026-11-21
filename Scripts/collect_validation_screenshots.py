#!/usr/bin/env python3
"""Rebuild the private, offline 19 November Photo Earth screenshot archive on macOS."""
import csv
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
DATA = REPO / ".local-test-data"
ROUND = DATA / "earth-20261119"
OUT = ROUND / "验收截图"
TEL = ROUND / "television"
EVID = ROUND / "evidence"
SCAN = DATA / "scan-gates"
EARTH = DATA / "2026-11-19-earth"
SLIDES = DATA / "slideshow-gates"
TMP = Path("/tmp")
IMAGE_TYPES = {".png", ".heic", ".jpeg", ".jpg"}
SCAN_DIRS = [TEL, EVID, ROUND / "unit", ROUND / "soak", EARTH, SCAN, SLIDES]
TEMP_RESULTS = [TMP / "pe-slides-dd/Logs/Test", TMP / "pe-scan-dd/Logs/Test",
                TMP / "pe-scan-ui-snap/Logs/Test", TMP / "photoearth-earth-dd/Logs/Test"]
STATE = OUT / "manifest.json"
ZONE = dt.timezone(dt.timedelta(hours=8))


def reference(path):
    return str(path.relative_to(REPO)) if path.is_relative_to(REPO) else str(path)


def printed_time(value):
    return dt.datetime.fromtimestamp(value, ZONE).isoformat(timespec="milliseconds")


def stable_json(path, data):
    temp = path.with_suffix(".writing")
    temp.write_text(json.dumps(data, ensure_ascii=False, indent=1))
    temp.replace(path)


def category(label):
    text = label.lower()
    if any(word in text for word in ("top shelf", "top-shelf", "topshelf", "journeyshelf", "homeshelflayout", "native-system-", "city-scroll", "native-mapkit-final-top-shelf", "native-mapkit-final-no-permission", "native-mapkit-final-app-phase", "native-mapkit-order-", "native-mapkit-switch-", "native-mapkit-system-", "系统主屏", "真机首卡")):
        return "系统主屏与旅程推荐"
    if any(word in text for word in ("permission", "consent", "music-explicit", "after-perm", "native-prompt")):
        return "权限与系统提示"
    if any(word in text for word in ("scan", "scope", "onboard", "candidate-step", "clean-state", "albumexclusion")):
        return "扫描与相册范围"
    if "continuousphotoviewing" in text:
        return "照片墙与详情"
    if any(word in text for word in ("journeypreference", "home screen preference", "recentjourneypreference")):
        return "设置"
    if any(word in text for word in ("slideshow", "soak", "hour", "playback", "ratio", "放映")):
        return "放映"
    if any(word in text for word in ("globe", "map", "neighborhood", "orbital", "camera", "tiles", "zoom", "pins", "iceland", "shanghai")):
        return "地球与地图"
    if any(word in text for word in ("wall", "detail", "photo view")):
        return "照片墙与详情"
    return "首页与导航"


def run(*args):
    return subprocess.run(args, capture_output=True, text=True, check=True).stdout


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def results_by_test(bundle):
    tree = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(bundle)))
    nodes = list(tree["testNodes"])
    results = {}
    while nodes:
        node = nodes.pop()
        if node.get("nodeType") == "Test Case":
            results[node["nodeIdentifier"]] = node.get("result")
        else:
            nodes.extend(node.get("children", []))
    return results


def sources_from_export(folder, owner, add, results=None):
    for test in json.loads((folder / "manifest.json").read_text()):
        test_id = test.get("testIdentifier", "")
        for item in test.get("attachments", []):
            filename = item["exportedFileName"]
            source = folder / filename
            if source.suffix.lower() not in IMAGE_TYPES or not source.is_file():
                continue
            label = item["suggestedHumanReadableName"]
            private_globe = (test_id.startswith("RealTVJourneyShelfTests/testNativeGlobePreviewContainsTheRegionalMapCredit")
                             and label.startswith("private-native-mapkit-globe"))
            if not private_globe and "/PhotoEarthUITests/" not in test.get("testIdentifierURL", "") and "screenshot" not in label.lower():
                continue
            if private_globe:
                label = "真机首卡 JPEG · 原生 MapKit 个性图（测试导出的卡面）"
            device = item["deviceName"]
            platform = "真机" if owner.is_relative_to(TEL) or device == "客厅" else "模拟器"
            status = "测试附件"
            if item.get("isAssociatedWithFailure"):
                status = "失败附件"
            elif results:
                status = {"Passed": "用例通过", "Failed": "用例失败", "Skipped": "跳过"}.get(results.get(test_id), status)
            origin = reference(owner)
            if owner.is_dir() and owner.suffix != ".xcresult":
                origin += "/" + filename
            add(source, dict(platform=platform, device=device, origin=origin, test=test_id, title=label,
                             time=printed_time(item["timestamp"]), clock="XCTest 采集时间", status=status,
                             category=category(test_id + " " + label + " " + owner.name)))


def manual_files(add):
    def save(path, platform, test, status="手工采集", clock=None, stamp=None):
        if not path.is_file():
            return
        add(path, dict(platform=platform, device="客厅" if platform == "真机" else "Apple TV 模拟器",
                       origin=reference(path), test=test, title=path.name,
                       time=printed_time(path.stat().st_mtime if stamp is None else stamp),
                       clock=clock or "文件修改时间", status=status, category=category(test + " " + path.stem)))
    for folder, platform in [(TEL, "真机"), (EVID, "模拟器")]:
        for path in sorted(folder.glob("*.png")):
            name = path.stem
            if name.startswith(("01-", "02-", "03-", "04-")):
                save(path, platform, "800 km 地球切换及返回 / globe")
            elif name in {"after-perm", "candidate-onboarding", "candidate-step", "clean-scan", "clean-state",
                          "debug-next", "music-explicit", "now", "one-click", "permission-current", "real-globe-live",
                          "real-home-loaded", "real-home", "soak-screen0", "Real-library-home", "debug-focus",
                          "real-slideshow-start"} or re.fullmatch("hour-milestone-[0-9]+", name):
                save(path, platform, name, status="附件副本" if name.startswith("hour-milestone-") else "手工采集")
            elif platform == "真机" and name.startswith("native-") and not any(
                    token in name for token in ("-small", "-preview", "-review", "-frame", "-grid")
            ):
                save(path, platform, name)
    user_home = TEL / "user-submitted/system-home-1416.png"
    if user_home.is_file():
        add(user_home, dict(platform="真机", device="客厅", origin=reference(user_home),
                            test="用户反馈 · 系统主屏缺少旅程海报",
                            title="用户提交的客厅系统主屏截图，14:16（570 × 334）",
                            time="2026-11-19T14:16+08:00", clock="画面右上角系统时钟，精确到分钟",
                            status="用户提交", category="系统主屏与旅程推荐"))
    save(SCAN / "Evidence/first-scan-scope.png", "模拟器", "首次扫描范围 / Scan Scope")
    for name in ("globe-ui-near.png", "globe-ui-step.png", "pe-scan-now.png", "pe-scan-current.png", "pe-scan-focus.png",
                 "pe-slide-current.png", "pe-slide-ongoing.png"):
        test = "扫描相册范围 / Scan Scope" if "-scan-" in name else "放映" if "-slide-" in name else "地球缩放 / Globe"
        save(TMP / name, "模拟器", test, "调试走查")
    for name in ("photoearth-native-map/iceland.png", "photoearth-native-map/shanghai-first.png",
                 "photoearth-native-map/shanghai-later.png", "photoearth-probe-iceland.png"):
        save(TMP / name, "模拟器", "原生 MapKit 瓦片对照探针", "调试走查")
    timeline = TEL / "playback-screen-samples/captures.csv"
    if timeline.is_file():
        with timeline.open() as stream:
            for row in csv.DictReader(stream):
                if row["status"] == "ok":
                    begin = dt.datetime.fromisoformat(row["beginUTC"]).timestamp()
                    end = dt.datetime.fromisoformat(row["endUTC"]).timestamp()
                    save(timeline.parent / row["frame"], "真机", "长时间放映 · devicectl 截屏（采集时缩为 JPEG）",
                         clock="采集请求起止中点", stamp=(begin + end) / 2)


def thumbnails(items):
    for key, item in items.items():
        target = OUT / "缩略图" / (key + ".jpg")
        if target.exists():
            continue
        # ImageIO via sips decodes both HEIC and PNG. Limit concurrent 4K decodes to one.
        tmp = target.with_suffix(".partial.jpg")
        run("/usr/bin/sips", "-s", "format", "jpeg", "-s", "formatOptions", "72", "-Z", "360",
            str(OUT / item["file"]), "--out", str(tmp))
        tmp.replace(target)


def build_index(archive):
    rows = []
    for key, item in archive["items"].items():
        src = sorted(item["sources"], key=lambda s: (not s["origin"].endswith(".xcresult"),
                                                      s["clock"] != "XCTest 采集时间", s["time"]))
        rows.append(dict(id=key, file=item["file"], sources=src))
    def sort_key(row):
        s = row["sources"][0]
        return (s["platform"] != "真机", s["title"].startswith("Screenshot "), s["status"] != "用例通过", s["time"])
    rows.sort(key=sort_key)
    doc = (Path(__file__).with_name("validation_screenshots_index.html")).read_text()
    safe = json.dumps(rows, ensure_ascii=False, separators=(",", ":")).replace("<", "\\u003c")
    tmp = OUT / "index.writing"
    tmp.write_text(doc.replace("__SCREENSHOTS__", safe))
    tmp.replace(OUT / "index.html")


def collect():
    os.nice(12)
    OUT.mkdir(mode=0o700, exist_ok=True)
    lock = (OUT / ".collect.lock").open("a")
    fcntl.flock(lock, fcntl.LOCK_EX)
    for name in ("原图", "缩略图"):
        (OUT / name).mkdir(exist_ok=True)
    data = json.loads(STATE.read_text()) if STATE.exists() else {"version": 1, "items": {}, "bundles": {}}
    items = data["items"]
    def add(source, info):
        key = digest(source)
        if key not in items:
            dest = OUT / "原图" / (key + source.suffix.lower())
            if not dest.exists():
                # Only link from a private, immutable xcresult export. A later
                # devicectl run can overwrite an existing manual filename in-place.
                if source.is_relative_to(OUT):
                    os.link(source, dest)
                else:
                    shutil.copy2(source, dest)
            items[key] = dict(file=str(dest.relative_to(OUT)), bytes=source.stat().st_size, sources=[])
        sources = items[key]["sources"]
        for index, existing in enumerate(sources):
            if all(existing[field] == info[field] for field in ("origin", "title", "test", "time")):
                sources[index] = info
                break
        else:
            sources.append(info)

    manual_files(add)
    exported = [d for parent in SCAN_DIRS for d in parent.glob("*/manifest.json")]
    exported.extend(d / "manifest.json" for d in [TMP / "pe-scope-exports2", TMP / "pe-scope-exports3",
                    TMP / "pe-scan-ui1-assets", TMP / "photoearth-street-tiles"] if (d / "manifest.json").is_file())
    for manifest in sorted(exported):
        sources_from_export(manifest.parent, manifest.parent, add)
    bundles = {p for d in SCAN_DIRS + TEMP_RESULTS for p in d.glob("*.xcresult")}
    bundles.update(p for p in TMP.glob("pe-scan-r[12].xcresult") if p.is_dir())
    pending = []
    for p in sorted(bundles):
        info = p / "Info.plist"
        if not info.is_file():
            pending.append(reference(p))
            continue
        signature = str(info.stat().st_mtime_ns)
        if data["bundles"].get(reference(p), {}).get("signature") == signature:
            continue
        try:
            summary = json.loads(run("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(p)))
            if not summary.get("finishTime"):
                pending.append(reference(p))
                continue
            results = results_by_test(p)
            for ext in ("png", "heic", "jpg", "jpeg"):
                with tempfile.TemporaryDirectory(dir=OUT, prefix=".export-") as scratch:
                    folder = Path(scratch)
                    run("xcrun", "xcresulttool", "export", "attachments", "--path", str(p),
                        "--output-path", scratch, "--filter", "*." + ext)
                    sources_from_export(folder, p, add, results)
            data["bundles"][reference(p)] = {"signature": signature, "result": summary.get("result")}
        except (subprocess.CalledProcessError, FileNotFoundError, KeyError, ValueError) as exc:
            pending.append(reference(p))
            print(f"待重试 {p.name}: {exc}", flush=True)
        stable_json(STATE, data)
    data["pending"] = pending
    data["excluded"] = {"evidence/visual-audit": "缺少独立设备截屏来源",
                        "电视录屏抽帧、预览拼图、DeviceHub 窗口": "视频或二次加工画面",
                        "原图库样本和分类器预览": "原始媒体"}
    for item in items.values():
        for source in item["sources"]:
            source["category"] = category(source["test"] + " " + source["title"] + " " + Path(source["origin"]).name)
    stable_json(STATE, data)
    print(f"已整理 {len(items)} 张原图，正在检查缩略图", flush=True)
    thumbnails(items)
    build_index(data)
    print(f"{len(items)} 张不同原图 · {sum(len(i['sources']) for i in items.values())} 条来源 · "
          f"{len(data['bundles'])} 个结果包 · {len(pending)} 个待重试；{OUT / 'index.html'}", flush=True)


if __name__ == "__main__":
    collect()
