# Apple TV 侧边栏导航

## 官方依据

- [Apple HIG — Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)：使用熟悉的符号与简短名称，侧边栏一般不超过两级层次，显示/隐藏遵循平台交互。
- [Enhancing your app’s content with tab navigation](https://developer.apple.com/documentation/swiftui/enhancing-your-app-content-with-tab-navigation)：`TabView` 应用 `.sidebarAdaptable` 后，tvOS 使用原生侧边栏，选中内容后缩为浮动胶囊。
- [WWDC24 — Migrate your TVML app to SwiftUI，14:59](https://developer.apple.com/videos/play/wwdc2024/10207/?time=899)：Apple TV app 的浮动侧边栏外观从 tvOS 18 开始提供给 SwiftUI 应用，平台负责相关行为。

文档查阅日期：2026-09-09。工程最低 tvOS 26.5，直接采用现有原生 API。

## 四个入口

| 入口 | 内容 | 选择后的路径 |
| --- | --- | --- |
| 首页 | 原有大地球、最近抵达玻璃 Dock 和货架 | 滚动地球 → 当前地表照片墙 → 照片详情 |
| 最近到访 | 按最后拍摄时间排序的地点与最新照片 | 地点照片墙 → 照片详情 |
| 国家与城市 | 国家列表 → 城市列表 | 整个国家或城市的照片墙 → 照片详情 |
| 设置 | 照片来源与索引统计、扫描、操作提示 | 原生照片授权/扫描流程；提示开关在本机保存 |

国家与城市放在内容区逐级展开，侧边栏保持四个固定目的地。地球探索隐去并禁用顶层导航 UI，保持同一个全屏 `MKMapView`，物理方向、触摸、中键和缩放工具条继续沿用现有操控。首页与国家列表保留视图和滚动位置，地球返回动画完成后才重新启用首页 Focus 并恢复出发卡片。分类照片墙使用独立全屏呈现，关闭回到来源集合，详情关闭回到原照片焦点。

## 数据与加载

国家/城市由地点摘要中的名称归组；相同城市名称在不同国家不会合并。未解析标签保留为「地名待完善」，匿名聚类不按兜底名称合并。跨语言或不同拼写尚不做名称归一化推断，分类准确度依赖现有 MapKit 解析结果。

最近到访以地点 `endDate` 倒序、地点 ID 为相同时间的稳定次序。集合封面从最近地点取最新照片。初始只准备前 15 个集合的代表地点，追加每批 10 个，图片驻留另有限制。

国家/城市照片按地点 ID 集合查询 SQLite，每页最多 48 张，按拍摄时间倒序和照片 ID 升序稳定分页。临时成员表避免大国地点数超过 SQL 参数数量限制。单页只解码有限照片，支持取消和错误重试，旧请求无法写回离开的页面。地球照片墙的 RTree 范围与原生屏内胶片规则保持原有语义。

## 验证

| 验证 | 结果与证据 |
| --- | --- |
| 单元测试 | `Verified.xcresult` 中完整 142 项 Swift Testing 测试通过，包含国家/城市分组、未知地名保留、最近时间稳定排序、5 万张照片的国家分页和硬上限。该轮 UI 曾发现焦点问题，不能将整个 bundle 称为全通过。 |
| 最终 UI 回归 | `FinalNavigation.xcresult` 的全部 6 条 XCUIRemote 流程通过：原有五条地球/缩放/货架流程，加四入口切换、国家与城市开墙、详情返回、非首个国家焦点恢复、设置提示开关及返回首页。 |
| Release | `release-final.log` 的 tvOS Release 无签名构建通过。 |
| 画面 | 在 1920 × 1080 pt 的 Apple TV 4K 模拟器复核原生浮动侧边栏、首页法务净空、大图集合、城市页、整国照片墙及设置；截图在 `final-screens/`。 |

以上文件均位于 `.local-test-data/sidebar/`。初轮测试中，侧边栏选中后额外右移使测试焦点走到第二张卡，已按原生行为修正测试。深层地球返回时的实际焦点回归则通过保留导航实例、返回动画完成后再启用首页和恢复卡片解决。原生 modal 保留的 tab 元素可能仍被 XCUI 枚举，因此照片墙隔离检查以不可交互、照片取得实际 Focus 与逐级返回共同验证，不能仅以元素 `exists` 判定泄漏。设置左右区域使用 `focusSection`，无需手工接管方向键。

本轮没有安装至 Apple TV 真机；实体 Siri Remote 的拖动手感与电视观看距离仍需设备确认。既有 MapKit 影像覆盖、残影和真机帧率限制不因侧边栏改动而视为解决。

### 后续真机安装（2026-09-09 22:12）

应用户要求重新构建当前工作区，包含侧边栏与缩放工具条内拖动，Debug 真机签名构建及严格签名校验通过，构建期间生产源码未变化。已安装至「客厅」Apple TV 4K 第三代并成功前台启动；启动不带 `--demo`，按正常流程读取本机偏好与既有照片索引。

证据位于 `.local-test-data/tv-install/20260909-221145/`：`device-build.json`、`device-codesign-verify.log`、`device-install.json`、`device-launch.json`。执行文件 SHA256 为 `9c7e89e32daa6811fc6a3c0f880189bcbdb0d00f109f5e862f93bbe9b0ab7baa`。临时安装构建 scheme 已移除，正式签名配置未改；本次安装不替代上述真机手感和帧率验收。
