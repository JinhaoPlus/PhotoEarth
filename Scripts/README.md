# Local simulator photo fixtures

## PhotoEarth release gate

Run `Scripts/release_gate.py doctor` to inspect Xcode, the release version and the tvOS simulator runtime. Run `Scripts/release_gate.py` before archiving. The Xcode Archive action checks the passing evidence against the current release inputs. [Verification skill](../.cursor/skills/verify-photoearth/SKILL.md) · [Feature map](../Docs/FeatureMap/README.md)

## UI localization workflow

UI and permission copy live in Xcode String Catalogs. Maintain translations in
Xcode. Native-language reviewers work in one language-specific Git branch and
directly edit only their locale values in `PhotoEarth/Localizable.xcstrings`
and `PhotoEarth/InfoPlist.xcstrings`, then deliver the change as a commit/PR.
Xcode Export/Import Localizations is a fallback for reviewers who cannot access
the repository. The app performs no runtime translation and sends no UI copy,
photo metadata, or place data to a translation service. See
`Docs/LOCALIZATION_NATIVE_REVIEW_BRIEF_2026-09-11.md` for edit boundaries and
the review checklist.

## Offline city catalog

Photo Earth, LensPin for iOS, and LensPin for macOS read the same bundled
`WorldCityAtlas.sqlite`. The database contains the public coordinates, boundaries,
city identities, aliases and reviewed localized names used for matching. The
release builder and its geographical input files live in the LensPin repository.
Photo Earth’s public validation scripts read the SQLite file directly.

From the Photo Earth checkout, run the following with the public GeoNames
`cities15000.txt` snapshot used for the 2,177 reference cities.

```bash
python3 Scripts/verify_city_catalog_coverage.py --check-release \
  --priority-gazetteer /path/to/cities15000.txt
python3 Scripts/verify_lenspin_city_parity.py /path/to/camera_photo_geo
```

The geographic gate preserves the original 289 landmarks and city centres. It
also checks public coordinates against observed Apple city names, documented
urban subdivisions and neighboring independent towns. For the 2,177 reference
points across the top 20 destinations it reports both the original name score
and the city-level score. A parent city qualifies only for the same region and
a reviewed source relationship to the reference entity. The frozen .4 public
fixture preserves the previously matched ID and name for each coordinate. Add `--priority-point-output <path.csv>` for
the per-coordinate results. The optional `--atlas <path.sqlite>` runs either
script against a candidate. The parity script checks both bundled SQLite files
and both copies of the Swift reader when using the default inputs.

The compressed fixture in `Scripts/Fixtures/` freezes the results of revision
`world-atlas-20261121.3` (catalog SHA-256
`31d32e4e20965eff976051a31cf60096b43f23030a837808d80eda8fe3196036`). It
records the existing 1,258-coordinate, eight-language sample and 56,191 English
cases at older public city reference points and nearby offsets. The parity
script runs both product adapters and checks each region, city identity, source
and displayed name across products. Changes from the frozen labels require
a matching child, parent and region from the independently maintained
`Tools/journey-catalog/world-city-parents.tsv`. Everything else must match
the historical labels. Pass `--city-parents <path.tsv>` for a source checkout
in another location. `--differences <path.tsv>` exports every change and its
classification. Use `--strict-migration` with the archived .4 SQLite database
for the original .3→.4 zero-difference gate. The fixtures are
development inputs outside the signed apps.

The full language audit is maintained in LensPin’s
`Tools/journey-catalog/audit_world_languages.py`. It replays the shared SQLite
reader and Top Shelf name functions for every record, checks them against the
stored alias, locale and fallback rules, and records exact language witnesses.
Its pinned historical TSV is one of the offline evidence inputs.

## Unsplash fixtures

`prepare_unsplash_simulator_library.py` builds 300 geotagged JPEG fixtures for local tvOS performance testing:

- 10 globally distributed destinations.
- 3 unique Unsplash photos per destination.
- 10 local derivatives per photo.
- Synthetic city-level GPS jitter when the downloaded image has no embedded GPS.
- Deterministic travel dates and coordinates.
- A JSON manifest containing photographer and source-page attribution.

The tool uses 10 Unsplash search requests and 30 tracked download requests, fitting the default 50-request/hour demo allowance. Generated data and credentials are ignored by Git.

## Configure

Create an application at <https://unsplash.com/developers>, then copy `.env.unsplash.example` to `.env.unsplash.local` and enter the Access Key. The Secret Key is not needed.

## Generate and import

With an Apple TV Simulator booted:

```bash
python3 Scripts/prepare_unsplash_simulator_library.py --import-simulator
```

The resumable output is written to `.local-test-data/unsplash-global-300/`. Rerunning reuses the cached API selection and downloaded source files.

Use `--refresh-selection` only when a fresh search is intentional because it consumes another 10 API requests.

## Run a real-device index in Simulator

A copied `travel-index-v3.sqlite` can be used to reproduce real-world map, place,
journey, and spatial-query load without modifying the source database. Put the
copy at `.local-test-data/device-index/travel-index-v3.sqlite`, build or run
PhotoEarth once in the booted Apple TV Simulator, and then run:

```bash
Scripts/install_sqlite_fixture_in_simulator.sh
```

The installer validates schema v3 and SQLite integrity, stops the Simulator app,
backs up its current index, and installs a copy into its cache directory. The
device's PhotoKit local identifiers do not exist in Simulator, so their images
remain unavailable. No build substitutes unrelated photos for missing IDs. Use
this copy only in a controlled read-only query/load test: normal launch reconciles
the index against the current Simulator library. For visual verification, scan
the imported public fixtures in that library, or explicitly launch `--demo` /
`--preparation-fixture`.

Import the 300-image fixture first if the Simulator photo library is empty:

```bash
python3 Scripts/prepare_unsplash_simulator_library.py --import-simulator
```

## 用 Mac 系统图库构造独立 Apple TV 模拟器

在项目根目录运行。素材、GPS 和照片 ID 只存放在本机的 `.local-test-data`。Mac 导出程序通过 PhotoKit 读取系统图库。它按年份分配数量，在一年内分散抽取连续四项，优先读取本机资源，数量不足时允许 PhotoKit 下载 iCloud 原始资源。图库汇总用 `0` 作为样本数即可单独运行。

```bash
umask 077
private_dir="$PWD/.local-test-data/private-fixture"
mkdir -p "$private_dir/export"
Scripts/PrivateLibraryFixture/build.sh "$private_dir/tools"
open -n -a "$private_dir/tools/PhotoEarthLibrarySample.app" --args "$private_dir/export" 5000 2026
```

等 `export/manifest.json` 出现后继续。首次运行需要在 macOS 系统弹窗中允许导出程序访问照片。选用新建的 tvOS 模拟器，设备名以「Photo Earth · 真实图库」开头。将下例的 `device_id` 设为它的 UDID。

```bash
xcrun simctl list devices available
xcrun simctl bootstatus "$device_id" -b
xcrun simctl install "$device_id" "$private_dir/tools/FixtureImport.app"
python3 Scripts/PrivateLibraryFixture/stage.py "$device_id" "$private_dir/export"
```

导入程序只在指定模拟器运行。它同时导入 Live Photo 的静态和动态资源，用系统 Photos API 重建拍摄时间、GPS、收藏、相册成员，相册名用本机编号。重复执行会复用已经入库的素材。脚本打印的 `import-summary.json` 给出按唯一 ID 读回的媒体数量、额外返回行、相册成员差异以及日期偏差。原始时间和地址缓存可能与系统导入后派生的字段不同，核对该文件后再作产品验收。

真实图库 UI 门禁使用 `PrivateLibrarySlideshowUITests` 和 `GlobeScaleUITests/testPhotoLibraryCityToNeighborhoodAndBack`。可在已授权的真实 Apple TV 上运行，XCTest runner 环境变量分别为 `PHOTOEARTH_PRIVATE_LIBRARY=1`、`PHOTOEARTH_PRIVATE_GLOBE_TEST=1`、`PHOTOEARTH_PRIVATE_SOAK=1`。真机一小时用例从首页启动，实际呈现首个素材后开始计时。私有截图、影片和 xcresult 保存在本机隔离目录。

### 旅途扫描门禁

`python3 Scripts/verify_lenspin_city_parity.py /path/to/camera_photo_geo` 先核对两边城市目录的 SHA-256，再编译两个项目的坐标匹配实现，逐一比较城市身份、地名、国家、ISO 代码及匹配来源。公开坐标取自旧版本目录、偏移样本和规则网格，按冻结结果检查迁移。

`JourneyScanGateTests` 使用临时 SQLite 库验证筛选优先级、重叠相册、重复回送、编辑与过期证据、目录更新及全量／增量等价性。`JourneyScanScopeUITests` 还会通过遥控器从首次选范围进入设置，核对四张合格素材在排除与恢复过程中的实际数量。该场景在名为 `Photo Earth · Scan Gates` 的独立 tvOS 模拟器中执行。新建并启动后运行下列命令，传入该模拟器的 UDID。Python 需安装 Pillow。

```sh
python3 Scripts/PrivateLibraryFixture/seed_scan_scope.py "$SCAN_SIM"
xcodebuild build -scheme PhotoEarth -destination "id=$SCAN_SIM" -derivedDataPath .local-test-data/scan-build
xcrun simctl install "$SCAN_SIM" .local-test-data/scan-build/Build/Products/Debug-appletvsimulator/PhotoEarth.app
xcrun simctl privacy "$SCAN_SIM" grant photos com.doupi.PhotoEarth.PhotoEarth
xcrun simctl privacy "$SCAN_SIM" grant location com.doupi.PhotoEarth.PhotoEarth
xcodebuild test -scheme PhotoEarth -destination "id=$SCAN_SIM" -parallel-testing-enabled NO \
  -only-testing:PhotoEarthUITests/JourneyScanScopeUITests \
  -only-testing:PhotoEarthTests/JourneyScanGateTests
```

种子程序通过 PhotoKit 在独立模拟器内创建五张合成图。两个重叠相册用于验证排除与恢复，另外十二个相册共用一张无 GPS 的图，用于验证长列表上下滚动时的列位置。重新验证首次安装时，先仅在该模拟器卸载 Photo Earth，再重新授权并运行。XCTest 附件保存首次范围、排除决定和恢复后页面的截图。

## 真机开发版的干净安装

收到明确安装许可后，在 Mac 构建并签名 tvOS 开发包，再用下面的命令安装到指定电视。脚本核对物理 tvOS 设备、签名及 PhotoEarth 的 bundle ID，卸载旧包，读取已安装应用列表确认已删除，最后安装并核实新包。系统可能再次显示照片授权。执行前需要留存的截图、录屏和开发诊断应先保存在 Mac。

```bash
python3 Scripts/install_development_on_apple_tv.py "客厅" /absolute/path/Debug-appletvos/PhotoEarth.app
```

Xcode Run／Test 会自行安装时，加 `--prepare-for-xcode` 完成同样的卸载与读回，再运行同一份已校验的包。完成 UI 测试后移除该次安装的测试 Runner，保留用户要体验的 PhotoEarth 开发版。

长播测试启动参数 `--slideshow-observe-media` 只在 Debug 构建生效。以下命令读回真机实际呈现账本，检查连续序号和同场素材重复，输出首末画面间隔和切换间隔。新版账本还提供地点和年份覆盖数、媒体种类、驻留条目数和抽样内存。完整观测时长以 XCTest 前台时钟为准。

```sh
xcrun devicectl device copy from --device "客厅" --domain-type appDataContainer \
  --domain-identifier com.doupi.PhotoEarth.PhotoEarth \
  --source Library/Caches/slideshow-observation.jsonl \
  --destination .local-test-data/tv-slideshow.jsonl
python3 Scripts/verify_tv_slideshow.py .local-test-data/tv-slideshow.jsonl
```
