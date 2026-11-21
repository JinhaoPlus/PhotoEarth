# Live Photo 与普通视频详情播放支持记录

日期：2026-09-12

## 1. 结论

Photo Earth 可以在原生 tvOS 详情页支持 Live Photo 与普通视频，不需要第三方播放器，也不需要把用户原始媒体复制到应用目录：

- Live Photo 使用 PhotosUI 的 [`PHLivePhotoView`](https://developer.apple.com/documentation/photosui/phlivephotoview?changes=_3_2)，由 [`PHImageManager.requestLivePhoto`](https://developer.apple.com/documentation/photos/phimagemanager/requestlivephoto%28for%3Atargetsize%3Acontentmode%3Aoptions%3Aresulthandler%3A%29) 取得 `PHLivePhoto`，以完整样式播放动态与声音。
- 普通视频使用 [`PHImageManager.requestPlayerItem`](https://developer.apple.com/documentation/photos/phimagemanager/requestplayeritem%28forvideo%3Aoptions%3Aresulthandler%3A%29) 取得系统准备的 `AVPlayerItem`，再由 `AVPlayer` / `AVPlayerLayer` 适屏播放。
- Live Photo 通过 [`PHAssetMediaSubtype.photoLive`](https://developer.apple.com/documentation/photos/phassetmediasubtype/photolive?language=objc) 识别；普通视频通过 `PHAsset.mediaType == .video` 识别并保存 `PHAsset.duration`。
- 两类请求都允许 PhotoKit 按需访问 iCloud，并使用系统请求进度与取消接口；应用不自行定位、下载或持久化媒体文件。

当前“普通视频”指 Photos 能返回 `AVPlayerItem` 的常规视频。360°、空间／沉浸式视频、RAW 特殊展示、剪辑、字幕／音轨选择、自动连播和循环不属于本轮范围。

## 2. 产品行为

1. 扫描同时枚举图片和视频，只索引具有合法 GPS 与拍摄时间的静态照片、Live Photo 和普通视频。
2. 三类媒体共用地点聚类、城市／国家分类、地球光点、当前画面严格投影、照片墙稳定分页与准确计数。
3. 照片墙和记忆地平线仍只加载静态缩略图，用克制的 Live Photo／视频图标提示可播放内容；视频附带时长。
4. 进入详情先显示墙预览或 3840 × 2160 适屏静态封面，不自动下载动态资源。
5. 用户按 Siri Remote 的 Play/Pause，或打开操作层聚焦「播放」，才请求动态内容。Live Photo 完整播放一次；视频支持播放、暂停、进度和播完后从头重播。
6. iCloud 请求显示真实进度。失败时保留静态封面和上下张导航，并允许重试。
7. 切换照片、退出详情或应用退入后台时，立即暂停并取消未完成请求；请求 token 与 generation 阻止迟到结果覆盖当前媒体。
8. 动态内容不预取、不进入静态图片缓存。同一详情最多一个动态媒体请求，整段视频不计入 `UIImage` 缓存预算。

## 3. 数据与升级

`PhotoMediaKind` 使用稳定整数值：静态照片 0、Live Photo 1、视频 2。SQLite schema 从 v4 升到 v5，`photos` 与 `scan_photos` 新增：

- `media_kind INTEGER NOT NULL DEFAULT 0`
- `duration REAL NOT NULL DEFAULT 0`

升级采用原地迁移：保留照片行、地点、RTree、旅程和多语言地名缓存，旧行先按静态照片继续可见。迁移会清除旧 PhotoKit 增量基线，使下一轮轻量全库元数据复核发现历史 Live Photo 和视频；不会仅因为增加媒体类型而删除可用索引或下载原始媒体。

由于此前视频完全不在索引内，升级复核后地点与总媒体数量可能增加，这是预期行为。无 GPS 或无拍摄时间的媒体仍不会进入旅行地球。

## 4. 主要实现位置

- `PhotoEarth/Domain/Models/TravelModels.swift`：媒体类型、时长与 schema v5。
- `PhotoEarth/Services/PhotoLibrary/PhotoLibraryService.swift`、`PhotoLibraryChanges.swift`：全量与增量扫描图片／视频元数据。
- `PhotoEarth/Services/Persistence/TravelIndexStore.swift`：媒体字段持久化及 v4 → v5 原地升级。
- `PhotoEarth/Features/PhotoViewer/PhotoDetailPlayback.swift`：PhotoKit 动态请求、取消隔离、Live Photo 与视频播放器生命周期。
- `PhotoEarth/Features/PhotoViewer/PhotoDetailView.swift`：海报优先、Play/Pause、进度、重试、媒体信息与后台暂停。
- `PhotoEarth/Features/PhotoViewer/ViewportPhotoWall.swift`、`PhotoEarth/Features/Globe/MemoryPhotoStrip.swift`：可播放媒体标记。
- `PhotoEarth/Localizable.xcstrings`、`PhotoEarth/InfoPlist.xcstrings`：8 种语言的媒体 UI 与 Photos 权限用途说明。

## 5. 自动验证

验证环境：Xcode 26.6、tvOS 26.5 Simulator、Apple TV 4K（第 3 代，1080p）。

- 媒体定向测试：10 个测试声明、24 次实际执行，0 失败。覆盖类型／时长、SQLite 往返、v4 → v5 保留式迁移、增量媒体编辑、按需请求、失败重试、切换取消及 8 种语言文案。
- 完整单元回归：282 个测试声明、345 次实际执行，0 失败、0 跳过。
- UI 回归：`ContinuousPhotoViewingTests.testContinuousViewingCrossesPageBoundaryAndReturnsToLastPhoto` 通过；验证详情操作层新增播放入口后，连续左右浏览、48 项分页边界和返回定位仍正常。
- 构建：tvOS 设备目标 Release、关闭代码签名，构建通过。
- 真机交付：Debug arm64 真机包完成严格签名验证；23:27 覆盖安装到“客厅”Apple TV 4K（第 3 代），23:28 以正常模式、空启动参数成功前台启动，PID 13509。没有清除数据、启用示例参数或主动触发图库重扫。
- 结果包：`/tmp/PhotoEarth-Media-Final-20260912/Logs/Test/Test-PhotoEarth-2026.09.12_22-36-33-+0800.xcresult` 与 `/tmp/PhotoEarth-Media-UI-20260912/Logs/Test/Test-PhotoEarth-2026.09.12_23-00-29-+0800.xcresult`。

## 6. 发布前真机验收

模拟器和合成测试无法证明 Photos 实际媒体交付质量。发布前必须在真实 Apple TV、真实 Photos 资料库和有声电视／功放上逐项复验：

- 本地 Live Photo：画面与声音完整，Play/Pause 响应正确，播放一次后停在封面／末帧状态可接受。
- 仅 iCloud Live Photo：进度真实可见，断网失败可重试，离开详情能取消。
- 本地与仅 iCloud 普通视频：比例、方向、声音、暂停、进度、播完重播正确。
- 至少覆盖横屏、竖屏、短视频、长视频，以及设备可播放的 HEVC／HDR 示例；确认色彩、解码与功放输出。
- 下载中快速切换上一项／下一项、按 Back、切后台再回来，确认旧媒体不会闪回或继续出声。
- 使用实体 Siri Remote 检查 Play/Pause 与操作层 Focus，不让播放按钮破坏连续左右浏览。
- 用大图库和弱网观察静态图 4／2 调度预算之外的单个动态请求，确认不会造成首页、地图或照片墙明显卡顿。

在这些真机项目完成前，只能表述为“原生 API、数据、UI 与自动回归已接入”，不能宣称 iCloud 弱网、声音、HDR／编解码或实体遥控器体验已经完成发布验收。
