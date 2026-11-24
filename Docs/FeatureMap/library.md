# 连接照片库与扫描

## 子功能

- 首次启动可连接 Photos，也可明确选择查看示例旅程。无权限、无可用旅行素材和扫描失败分别提供恢复入口。
- 首轮可选扫描范围。准备页显示实际进度，可暂停、继续，在索引可用后进入同一张旅行地球。已有图库打开时先展示有效索引，再后台复核 Photos 变更。
- 「照片与扫描」可查看统计和分项原因、调整排除相册与相机筛选、重新扫描、补齐地点名称或重建本机索引。切换「隐藏疑似途经照片」即时更新可见素材，关闭后恢复。

## 用户怎么进入

- 首次打开，选「连接照片图库」后授权并确认「扫描时需要排除的相册」，或选「探索示例旅程」。从欢迎页或示例设置打开首扫范围后，Back 回原入口，「开始扫描」启动整理。
- 已连接时打开侧边栏「设置」，进「照片与扫描」。在准备页也可打开扫描范围或回到可浏览的地球。

## 用 XCTest 怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 从欢迎页选示例，再走独立的准备路径。 | 欢迎页能选择两个入口。准备中可暂停和继续，Back 保留整理状态并恢复来源焦点，完成后进入同一地球，从设置能重开准备页。 [LibraryPreparationUITests](../../PhotoEarthUITests/LibraryPreparationUITests.swift) |
| 在欢迎页和示例设置打开首扫范围，按 Back 后重开。取消一次已有图库的范围编辑。 | 恢复入口焦点及原范围，「开始扫描」「保存范围」分别提交首扫和编辑。 [JourneyScanScopeUITests](../../PhotoEarthUITests/JourneyScanScopeUITests.swift) |
| 图库检查结束后展开「扫描详情」。 | 准备页显示「图库检查完成」，详情列出三类地名匹配结果。所有到访均已查过时，隐藏「继续补充地点名称」。 [LibraryPreparationTests](../../PhotoEarthTests/LibraryPreparationTests.swift) · [LibraryPreparationUITests](../../PhotoEarthUITests/LibraryPreparationUITests.swift) |
| 在设置中更改每次到访的最低数量。 | 选预设后按 Back 放弃草稿，「保存」提交，退出后焦点都回设置项。 [LibraryPreparationUITests](../../PhotoEarthUITests/LibraryPreparationUITests.swift) |
| 预置有交集的两个相册，保存排除，再取消排除。 | 重叠资产只计一次，符合资格的外部对照保留。解除排除后恢复应有素材。 [JourneyScanScopeUITests](../../PhotoEarthUITests/JourneyScanScopeUITests.swift) · [RealTVAlbumScopeUITests](../../PhotoEarthUITests/RealTVAlbumScopeUITests.swift) |
| 切换「隐藏疑似途经照片」，并覆盖全库被隐藏的情况。 | 可见数量即时变化，关闭后恢复；全隐藏时仍能回设置恢复。 [TransitFilteringUITests](../../PhotoEarthUITests/TransitFilteringUITests.swift) |

## 容易验错的地方

- 最近到访最低素材数决定卡片是否出现。相册排除、Photos 权限和扫描资格决定资产能否被读取，两者改动后的验法不同。 [到访与最低素材数](places.md) · [扫描规则](../../rules/library-scan.md)
- 用准备流程的测试数据核对进度与 Focus。核对实际相册成员、权限变化或 iCloud 相机证据时，使用当前设备的真实 Photos 资产。相机证据处于未知时保留素材，界面有独立计数。 [扫描入口实现](../../PhotoEarth/ContentView.swift) · [设置实现](../../PhotoEarth/Features/Settings/SettingsView.swift) · [扫描和相册实体电视验收](../JOURNEY_REFACTOR_ACCEPTANCE_2026-11-19.md)
