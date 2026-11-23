# PhotoEarth 功能地图

这份地图按用户能到达的入口整理当前工作区中的 tvOS 功能。每页说明子功能、入口、可用测试和通过时应看到的结果。项目规则和历次验收从对应页面跳转。

| 用户从哪里开始 | 功能 | 用户能看到的结果 |
| --- | --- | --- |
| 原照片墙入口、放映开场的「开始放映」 | [七天试用与买断](../../rules/product-engineering.md#七天试用与买断) | 共用原首页和侧边栏。首次选定的一段旅程可免费回看和放映；取消回到原操作，解锁后继续。 |
| 欢迎页，或设置中的「照片与扫描」 | [连接照片库与扫描](library.md) | 连接 Photos、进入示例、调整扫描范围、暂停或继续准备，最后进入旅行地球。 |
| App 原生侧边栏 | [首页、最近到访、地点](places.md) | 首页按城市浏览，最近到访按次浏览，「地点」先按国家或地区、再按城市浏览。 |
| 侧边栏「那年今日」 | [同月同日的照片](../../PhotoEarth/Features/Places/OnThisDayView.swift) | 切换月日，浏览连续年份刻度和空年份，原位展开、看详情或跨年放映。[遥控器端到端用例](../../PhotoEarthUITests/OnThisDayUITests.swift) |
| 首页「滚动地球」、首页城市卡、照片详情小地球 | [操控地球与查看当前画面](globe.md) | 用遥控器转动和缩放，在卫星与地图间切换，中键打开照片墙。 |
| 首页地球、到访、国家、城市或地图回看 | [照片墙、详情与媒体](photos.md) | 在同一范围内翻页、跨页连续观看，查看地点信息或播放 Live Photo 与视频。 |
| 照片墙「地图回看」 | [地图回看](map-review.md) | 用照片图钉查看地图画面，再打开该画面照片墙，返回来源时继续浏览。 |
| 首页或照片墙「放映」 | [放映](slideshow.md) | 主动开始整库或固定范围放映，暂停选片，退出后回到来源。 |
| 放映开场页或放映中右上角的配乐按钮 | [在线配乐与 Apple Music](music.md) | 选来源、分类或曲目，或关闭本场配乐。 |
| Apple TV 主屏第一排的 PhotoEarth 图标 | [Apple TV 主屏 Top Shelf](top-shelf.md) | 查看地球首卡和最近城市海报，直接进入地球或对应城市照片墙。 |

## 入口相似，照片范围各有定义

| 入口 | 照片墙范围 |
| --- | --- |
| 最近到访卡 | 该次访问的可见素材。 |
| 国家页的「查看所有照片」 | 该国各地点的可见素材。 |
| 地点中的城市卡、Top Shelf 城市海报 | 所选国家或地区内该城市的可见素材，覆盖该城市的多次访问。 |
| 首页城市卡进入地球后按中键 | 保留该城市的范围。选「改看当前画面」后，中键按实际地图画面圈定。 |
| 照片详情小地球进入探索后按中键 | 有稳定归属时范围为该城市，否则按当前画面圈定。 |
| 首页「滚动地球」或地图回看中按中键 | 冻结按键松开时的原生地图画面，按实际投影筛选。 |

## 共用设置与检验

- 「照片与扫描」管照片资格和扫描状态。「每次到访的最低数量」管首页、最近到访和 Top Shelf 的到访展示。「Apple TV 主屏幕」管 Top Shelf；「地球操作」管操作提示和首次影像等待。聚焦左下角的「解锁完整版」即可在右栏查看试用状态和一次性购买选项，购买后原位显示「已解锁完整版」。各设置的作用范围见对应功能页。 [设置入口](../../PhotoEarth/Features/Settings/SettingsView.swift)
- 照片权限或排除范围收窄时，检查已经打开的墙、详情、地图、正在播放的素材及系统主屏。集合的分页范围保持稳定，已撤回的照片需要立即移除。 [图库规则](../../rules/library-scan.md) · [照片墙规则](../../rules/photo-browsing.md) · [Top Shelf](top-shelf.md)
- 界面与地名跟随 Apple TV 为 App 解析的语言。日期、数字与读屏名称随语言变化，集合成员依靠稳定地点身份。用 `LocalizationSmokeUITests` 驱动各语言入口，另在系统设置下检查 VoiceOver、减少动态效果、降低透明度。 [本地化规则](../../rules/localization.md) · [语言冒烟测试](../../PhotoEarthUITests/LocalizationSmokeUITests.swift) · [离线地名验收](../WORLD_CITY_ATLAS_ACCEPTANCE_2026-11-21.md)
- 用例链接表示可复验的入口。示例和模拟器适合核对导航、Focus、照片成员和分页。真实 Siri Remote 触控、Apple TV 主屏、iCloud 媒体与声音需在相应真机环境核对。已有记录按日期和设备引用。 [验证规则](../../rules/validation.md) · [真机安装授权](../../AGENTS.md#真机安装授权)

## 发布与单项复验

产品统计的事件字典、看板与漏斗口径见[用户动线与看板](analytics.md)。

新版本归档前从工程根目录运行 `Scripts/release_gate.py`。它会准备独立模拟器并检查完整的必跑集合。失败后可用下面的命令单独复现某个入口。证据位置及归档条件见[发布验证技能](../../.cursor/skills/verify-photoearth/SKILL.md)。

从工程根目录运行。用 `xcrun simctl list devices available` 查 tvOS 模拟器 ID。替换 `TVOS_SIMULATOR_ID` 和 `-only-testing` 指定的用例。下面的用例自带示例数据。

```sh
xcodebuild test -project PhotoEarth.xcodeproj -scheme PhotoEarth \
  -destination 'platform=tvOS Simulator,id=TVOS_SIMULATOR_ID' \
  -parallel-testing-enabled NO \
  -only-testing:PhotoEarthUITests/ExperienceScopeUITests/testCityScopeSurvivesDraggingUntilExplicitCurrentViewSwitch
```
