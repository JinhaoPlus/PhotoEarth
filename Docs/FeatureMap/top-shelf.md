# Apple TV 主屏 Top Shelf

## 子功能

- Apple TV 主屏第一排聚焦 PhotoEarth 时，系统可显示动态内容。首卡是宽幅 MapKit 地球，后面最多 24 张城市海报。前五座城市与 App 首页最近城市排序对齐，向右可浏览更早到访。
- 地球首卡深链进入直接操控；城市海报直达该城市的可见照片墙。代表访问用于展示和封面，墙包含该城市的多次可见访问。
- 关闭最近城市主屏展示会撤下动态内容。扩展校验当前 Photos 权限和发布快照，从本机共享钥匙串与 PhotoKit 取得发布内容。

## 用户怎么进入

- 在 Apple TV 主屏第一排聚焦 PhotoEarth 图标，进入动态横排。选首卡滚动地球，或选城市海报进入照片墙。
- 在 App 内「设置 → Apple TV 主屏幕」切换「显示最近到访的城市」，再回系统主屏等 tvOS 刷新。

## 用 XCTest 和 Apple TV 主屏怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 发布足够的最近城市，在 Apple TV 主屏对照 App 首页首排并向右翻。 | 显示宽幅地球和对应城市海报，前五张与首页同序，之后按序接续。 [RealTVJourneyShelfUITests](../../PhotoEarthUITests/RealTVJourneyShelfUITests.swift) · [实体主屏记录](../TV_TOP_SHELF_JOURNEYS_2026-11-19.md) |
| 选地球首卡，再分别开一张靠前和一张较早的城市海报。 | 地球可以立即接管遥控器；各城市跳到正确照片墙，数量与可见索引成员一致。 [RealTVJourneyShelfUITests](../../PhotoEarthUITests/RealTVJourneyShelfUITests.swift) · [RealTVJourneyShelfTests](../../PhotoEarthTests/RealTVJourneyShelfTests.swift) |
| 关闭偏好或撤回图库权限，等待该轮新发布。 | 动态内容撤下；从旧链接打开时，当前资格仍需通过核对。 [JourneyShelfTests](../../PhotoEarthTests/JourneyShelfTests.swift) · [JourneyShelfFormatTests](../../PhotoEarthTests/JourneyShelfFormatTests.swift) · [实体主屏记录](../TV_TOP_SHELF_JOURNEYS_2026-11-19.md) |

## 容易验错的地方

- App 内首页和深链断言可以查成员或路由。系统横排的刷新、真实像素和焦点，需要看 Apple TV 主屏本身。运行真机用例前遵循项目的安装授权。 [真机安装授权](../../AGENTS.md#真机安装授权) · [验证规则](../../rules/validation.md)
- 整排展示依赖可用快照及至少一张真实海报。排查空货架时，分别查主屏图标行、快照、封面和系统调用回执。 [发布实现](../../PhotoEarth/App/JourneyShelfPublication.swift) · [扩展实现](../../PhotoEarthTopShelf/ContentProvider.swift) · [Top Shelf 规则](../../rules/places-covers.md#首页与-top-shelf)
