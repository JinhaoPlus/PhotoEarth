# 风景优先封面：方案与实现

日期：2026-10-11。适用首页城市卡片、国家与城市分类、由这些入口代表的照片集合。最近到访继续用该次访问的最新照片；不修改集合排序、照片墙排序、地图图钉封面或放映选片。

## 产品规则

风景包括自然景色、建筑与城市景观。横图不是风景的充分条件。优先选择可信场景分类、没有大面积人脸、非 utility、质量不明显偏低的照片；在合格候选中结合美学、人物占比、收藏与横向构图排序。景色中小人物不排除，竖图也能入选。没有合格结果继续使用当前最新照片封面，不删除或隐藏照片。

首次显示已有封面，页面不等待分析。停止浏览、进入其他页面、退入后台或索引变化时取消过期请求；替换封面不改变卡片尺寸、行顺序、集合成员或 Focus。分析预览可作为新封面的首帧，随后由原有图片管线取得显示尺寸。

## Apple 能力依据

- [VNClassifyImageRequest](https://developer.apple.com/documentation/vision/vnclassifyimagerequest)：设备端图像分类，使用 revision 2。本机 AppleTVOS26.5 SDK 标注 tvOS 13 起可用；revision 2 从 tvOS 17 起可用，头文件说明它改善准确度、时延和内存。
- [VNCalculateImageAestheticsScoresRequest](https://developer.apple.com/documentation/vision/vncalculateimageaestheticsscoresrequest)：tvOS 18 起可用，提供 overallScore 和 isUtility。是可选质量信号，模型失败时保留分类功能。[WWDC24](https://developer.apple.com/videos/play/wwdc2024/10163/) 解释 overallScore 范围 -1 至 1、utility 的含义。
- [VNDetectFaceRectanglesRequest](https://developer.apple.com/documentation/vision/vndetectfacerectanglesrequest)：tvOS 11 起可用，仅检测人脸框，不识别人物身份。
- [PhotoKit 网络策略](https://developer.apple.com/documentation/photos/phimagerequestoptions/isnetworkaccessallowed)：图片不在本机时可以禁止下载，无法获取不代表照片没有风景。

2026-10-11 在 Mac 上实际枚举 revision 2 的 supportedIdentifiers，确认 mountain、beach、forest、cityscape、building、skyscraper、sunset_sunrise 等标签。采用完整标识白名单，不能用 mountain 子串匹配 bernese_mountain（犬种），也不能仅凭 sky 就认定为风景。该枚举不是 Apple TV 上的识别准确率验证。

## 有限候选与资源预算

1. 只对实际可见首页卡片及分类图片驻留窗口执行，停留 600 ms 才开始；保留现有 15 + 10 地点准备预算。
2. 每个集合最多选择 6 次访问，按访问时间均匀取样，包含最近与最早访问；合计最多 24 条照片元数据。
3. 每次访问通过 SQLite 所属地点／时间索引读取最新、收藏及分散时间阈值前的照片。单次 SELECT 最多一条结果；去重后可能不足 24 条，不补扫全集。时间阈值采样可能遗漏稀疏或连拍间的最佳图片，因此只承诺风景优先，不能承诺全库最优。
4. 排除普通视频候选，Live Photo 仅使用静态预览；不请求动态资源。遵守当前路过照片隐藏策略，不跨集合选图。
5. 请求长边约 512 px、aspectFit 的完整构图预览，处理正确方向；不下载原图用于识别，不接受 degraded 帧作为持久评分。
6. 应用共享 FIFO 串行执行；PhotoKit 请求通过现有 SharedPhotoImageScheduler，Vision 在独立 actor 上执行。每次本机分析之间让出约 40 ms。不会因几十个卡片并发下载／识别。
7. 本机结果已有合格封面则不为优化继续下载。否则仅对最多 2 个缺失候选尝试 iCloud 小预览，沿用共享调度器超时与取消。小预览请求仍可能触发 Photos 的底层资源获取，不能承诺固定下载字节数。
8. 图像分类模型不可用时停止本次候选推理并冷却 60 秒，不把模型错误当作云端图片缺失继续下载。

## 评分与缓存

初始阈值集中在 ScenicCoverPolicy / ScenicCoverAnalysis：风景置信度至少 0.45、最大人脸占整图面积小于 0.12、isUtility 为 false；有美学评分时至少 -0.4。合格候选按 `scenery + aesthetics × 0.25 - largestFace × 2 + 收藏 0.06 + 横图 0.04` 排序，平分按时间倒序、照片 ID 升序稳定打破。以上均为初始产品参数，需用授权真实图库验证误判后调整，不能把分类置信度当作校准概率或把美学分当作用户情感价值。

SQLite 新增 cover_analysis 派生表与所属地点／收藏／时间索引，采用兼容的附加表，不提高主 schema 版本、不触发全库重扫。表仅保存照片引用、来源索引 generation、策略版本和少量评分，照片原始内容仍来自 PhotoKit。国家与城市共享每张照片的分析结果，不重复推理。

集合选定封面在有界内存 memo 中保留（最多 64 个条目）；重启后最多重读 24 条候选与对应评分，即可重新确定封面，不需要重新推理已成功分析的照片。完整分析结果保持到集合或索引变化；存在暂不可用照片时 60 秒后允许后续浏览重试，不自动轮询。未下载、失败、取消都不写成负分类。索引 generation 或策略版本不符则不复用；全量索引提交清除旧评分；PhotoKit 编辑／删除通知逐项删除评分并取消旧任务，新的选择先等待删除完成。

不写入 iCloud KVS、不修改用户照片、不上传图片／分析结果。诊断只使用固定事件或聚合计数，不包含照片 ID、精确坐标、地名或分类详情。

## 实现位置

- `Domain/Models/ScenicCover.swift`：规则、稳定排序、候选访问预算与存储协议。
- `Services/PhotoLibrary/ScenicCoverSelector.swift`：可取消共享队列、预览请求、Vision、集合短期 memo。
- `Services/Persistence/TravelIndexStore.swift`：有界索引读取与派生评分缓存。
- `App/AppModel.swift`：共享服务、来源／生命周期／编辑失效。
- `Features/Globe/OverviewContentModel.swift`：首页可见卡片渐进封面选择。
- `Features/Places/PlaceLibraryView.swift`：国家／城市集合全体成员候选；最近到访不启用。
- `Services/PhotoLibrary/OverviewPhotoKitRequester.swift`：复用已分析的小预览作为封面首帧。

## 验证边界

自动测试覆盖 5 万张候选上限、跨访问取样、真实成员与隐藏过滤、缓存重开／来源隔离／编辑删除、人物和 utility 降权、稳定排序、网络预算、共享缓存、串行／取消／迟到结果、模型错误降级，以及首页先显示最新照片、随后替换封面而不改变布局与 Focus。测试使用合成评分，不能证明模型对用户照片的准确率。

还需 Apple TV 上验证所有支持设备的模型可运行性、实际 Vision 时延、iCloud 下载成本、分类误判与长时间地图帧率。没有用户明确安装要求，不安装电视；构建和模拟器验证不能替代真机验收。

### 本轮已取得的证据

- 50 项定向单元测试通过（ScenicCoverTests、OverviewContentTests、PlaceCollectionTests、OverviewThumbnailTests、TransitFilteringTests），包括 5 万张合成照片的候选查询；结果包 `/tmp/photoearth-mapreview-build/Logs/Test/Test-PhotoEarth-2026.10.11_20-17-58-+0800.xcresult`，日志 `/tmp/photoearth-scenic-final-tests.log`。
- 最后补充集合重访重试、失败 memo 上限及旧任务不能清理新任务的边界后，最终源代码的 ScenicCoverTests 和 OverviewContentTests 共 21 项再次通过；分轮去重共 51 项单元测试。日志 `.local-test-data/scenic-covers/final-core-tests.log`。
- 1 条国家／城市／照片墙／详情／来源 Focus／设置的侧边栏 UI 流程通过，使用明确 demo 数据（不执行封面 Vision）。已复核 1920 × 1080 国家卡片截图；附件保存 `.local-test-data/scenic-covers/ui/`。该截图只证明布局与原有导航，不证明真实用户风景选片效果。
- 最终源代码 tvOS Release 无签名构建通过（`.local-test-data/scenic-covers/release.log`），使用 `-jobs 1 SWIFT_COMPILATION_MODE=incremental` 降低编译资源峰值，仍保留 Release 的优化与设备目标。之前的两次构建因磁盘空间不足失败，未计为通过，也未扩大清理用户资料范围。
- 在 Mac 上使用真实 Apple Vision 分析项目 DemoBanff、DemoParis、DemoTokyo 示例图片，分别得到 mountain、bridge、building 等高置信分类及非 utility 美学结果；这不是 Apple TV 模型、图库或时延验收。
- 本轮没有安装或启动 Apple TV 真机新版本；没有修改 PhotoKit 图库或触发全库图片识别。
