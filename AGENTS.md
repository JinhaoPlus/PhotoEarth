# Photo Earth 项目约定

适用于 `photo_earth/` 下的设计、实现、测试和文档。遇到新的明确需求，以用户最新要求为准，并同步更新对应规则。开始任务时先判断前提是否成立，再读取下方相关细则。涉及数字、行为和验证结论时，以当前代码、数据或实测为依据。

## 产品方向

- Photo Earth 是原生 Apple TV 旅行照片应用。用户授权后，应用用 Photos 中的拍摄时间和真实 GPS，在设备端生成到访、城市与旅程。用户无需手动导入或整理照片。
- 大屏体验优先呈现地球、真实照片和个人记忆。用电影感的构图、尺度、光影和节奏，控件保持克制。主地球用柔和地点亮点和照片表达记忆，旅程数据继续保留，地图上不画地点之间的连线。
- SwiftUI 使用原生 tvOS 导航、Focus、sheet 与 Liquid Glass。地球用 MapKit，媒体用 PhotoKit／PhotosUI／AVFoundation。尊重 Reduce Motion、Reduce Transparency、VoiceOver 与地图署名的可见性。

## 全局边界

- Photos 是照片、拍摄日期与 GPS 的唯一事实来源，应用只读。真实坐标用于原生投影与图钉。城市匹配在设备端使用与 LensPin 共用的一份随 App 打包的离线 SQLite，全应用反向地理编码请求数为零。单张照片地址只显示当前资产已有的 Photos 缓存。
- 用户排除的相册和当前 Photos 权限适用于所有入口、缓存和正在播放的画面。日志省略用户照片 ID、精确坐标和媒体内容。KVS 仅同步轻量偏好。
- SQLite 派生索引可清理、可重建。启动读摘要，照片按需查询。集合墙固定成员范围，当前画面墙冻结原生投影，准确总数独立于分页与胶片抽样。旧任务的结果需经取消和版本检查后才能发布。
- 首页、最近到访、国家与城市、设置使用原生侧边栏。保留常驻地球，按来源恢复 Focus。遥控器触摸和实体按键分别路由。直接操控地球时，中键松开圈定画面，Play/Pause 呼出缩放工具条。
- 主地球从卫星连续缩放到街区。以 MapKit 实际距离 800 km 为双向交接点，近景显示真实 GPS 照片图钉。放映由用户启动，支持整库或固定墙范围，按页选片、去重并继续播放。首次 Apple Music 授权只由用户主动进入该来源触发。

## 发布门禁

**每个发布构建都必须通过测试门禁，包括 TestFlight 测试版和 App Store 正式版。** 确定版本号和构建号后，在工程根目录运行 `Scripts/release_gate.py`。只有当前发布构建取得通过记录，才能归档、上传或提交审核。

门禁失败时停止发布，修复后重新运行。版本号、构建号、源码、资源、测试或门禁配置发生变化后，须重新通过门禁。详见[验证规则](rules/validation.md#新版本归档门禁)。

## 真机安装授权

- 只有用户明确要求安装到 Apple TV 真机电视上时，才允许执行真机安装，包括通过 Xcode Run／Test 自动安装。
- 每次获准安装开发版，先完成新包构建和签名校验，再从指定电视删除旧版 PhotoEarth，确认已卸载后才安装。使用 `Scripts/install_development_on_apple_tv.py`；Xcode 将负责安装时，先用其 `--prepare-for-xcode` 路径。适用于同版本号重装。开发验收结束清理本轮临时安装的测试 Runner。
- 常规开发、修复、构建、签名校验和模拟器测试不包含真机安装授权；不得因设备已连接、此前安装过，或文档要求真机验证而擅自安装。
- 未获得明确安装要求时，完成可进行的构建和模拟器验证，并如实说明尚未验证的真机体验。

## 按任务查阅规则

| 任务 | 细则 |
| --- | --- |
| 产品方向、工程分层、SQLite、KVS、并发和隐私 | [产品、工程与数据](rules/product-engineering.md) |
| Photos 授权、扫描流程、相册排除、相机证据、疑似途经 | [照片库扫描](rules/library-scan.md) |
| 离线地名、访问与城市身份、最低素材数、封面与 Top Shelf | [到访、城市和封面](rules/places-covers.md) |
| 侧边栏、首页、货架、列表、材质、Focus 恢复 | [导航与首页](rules/navigation.md) |
| MapKit、镜头、底图、尺度交接、远景照片带 | [主地球](rules/globe.md) |
| 实体按键、全触面拖动、缩放工具条、遥控提示 | [Siri Remote](rules/siri-remote.md) |
| 地图回看、近景照片图钉、聚合与准确计数 | [地图回看](rules/map-review.md) |
| 照片墙范围与分页、详情、图片调度、Live Photo 与视频 | [照片浏览](rules/photo-browsing.md) |
| 地球放映、选片、转场、暂停及两种配乐来源 | [地球放映](rules/slideshow.md) |
| String Catalog、Locale、中文文案与辅助功能 | [本地化](rules/localization.md) |
| 发布门禁、测试范围、模拟器与真机验收 | [验证](rules/validation.md) |

常驻规则维护在本页，功能细节维护在对应的 `rules/` 文件。方案和按版本记录的验收证据保存在 `Docs/`。旧版决定、调试记录与被替换段落见 [历史记录](Docs/AGENTS_HISTORY.md)。

查找用户入口、照片范围和验收用例，见 [PhotoEarth 功能地图](Docs/FeatureMap/README.md)。

当前改造的项目资料见 [旅途扫描与长时间放映方案](Docs/JOURNEY_SCAN_AND_LONG_SLIDESHOW_PLAN_2026-11-19.md) 和 [重构验收](Docs/JOURNEY_REFACTOR_ACCEPTANCE_2026-11-19.md)。
