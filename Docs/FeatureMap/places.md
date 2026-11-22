# 首页、最近到访、国家与城市

## 子功能

- 侧边栏提供首页、最近到访、国家与城市、那年今日和设置。首页保留卫星地球，首排展示最近抵达的城市，向下按年份浏览更多城市。
- 最近到访每次访问一张卡，按访问结束月分组。同一城市去过多次时，可分别打开每次访问。
- 国家与城市先浏览国家，再选择该国某个城市或整个国家。离线地名将同一城市的多个到访归在一起。地名待完善的访问仍可浏览，保留真实 GPS。
- 「旅程最低素材数」默认 5，可设为 1 至 1,000。最近到访按每次访问的可见定位素材数判断是否展示。首页和 Top Shelf 先筛达标访问，再选每城最近的一次做代表。之后打开城市照片墙仍可看该城全部可见素材。

## 用户怎么进入

- 打开侧边栏选「首页」，从「滚动地球」向下进入最近城市和年份货架。选城市后先进入该城市的地球探索。
- 选「最近到访」，从月份内选一张访问卡直达该次照片墙。
- 选「国家与城市」，进一个国家后选择「查看所有照片」或某张城市卡，进入对应集合墙。
- 首页、最近到访和国家与城市向下浏览后，按 Back 先回页首。顶层页首再按交给原生侧边栏，国家详情页首再按回国家列表原卡片。
- 在「设置 → 照片与扫描」调整「旅程最低素材数」。

## 用 XCTest 怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 用遥控器走完首页、最近到访、国家与城市和设置，进国家和城市照片墙再返回。 | 回到原页面和原卡片。国家页保留「查看所有照片」，页首 Back 退回原国家卡片。首页从城市探索退出回同一张城市卡。 [SidebarNavigationTests](../../PhotoEarthUITests/SidebarNavigationTests.swift) · [PhotoEarthUITests](../../PhotoEarthUITests/PhotoEarthUITests.swift) |
| 将首页、最近到访、国家列表或单个国家的城市列表滚到下方，再按两次 Back。 | 第一下回页首，聚焦「滚动地球」、第一张卡或「查看所有照片」。第二下移到原生侧边栏或退回原国家卡。 [OverviewScrollingUITests](../../PhotoEarthUITests/OverviewScrollingUITests.swift) · [SidebarNavigationTests](../../PhotoEarthUITests/SidebarNavigationTests.swift) · [RecentVisitFocusUITests](../../PhotoEarthUITests/RecentVisitFocusUITests.swift) |
| 从最近到访双列移动到中间只有一张卡的月份，再继续上下滚动。 | 中间月份能聚焦，往返时行与封面稳定。同城的不同访问分别有自己的日期和封面。 [RecentVisitFocusUITests](../../PhotoEarthUITests/RecentVisitFocusUITests.swift) |
| 滚动大示例库，模拟慢图。 | 图片慢时卡片仍可聚焦，离开子页面再返回能恢复位置。 [OverviewScrollingUITests](../../PhotoEarthUITests/OverviewScrollingUITests.swift) |
| 修改最低素材数并重启，核对两次到访素材数不同的同城样本。 | 设置值能读回。首页、最近到访和 Top Shelf 按门槛更新，城市墙仍包含该城的可见素材。 [OverviewContentTests](../../PhotoEarthTests/OverviewContentTests.swift) · [JourneyScanGateTests](../../PhotoEarthTests/JourneyScanGateTests.swift) · [JourneyShelfTests](../../PhotoEarthTests/JourneyShelfTests.swift) |

## 容易验错的地方

- 首页城市卡显示的访问素材数、最近到访卡的独立范围、整座城市的照片墙总数各有口径。检查封面时同时核对代表访问和封面资产资格。 [首页实现](../../PhotoEarth/Features/Globe/GlobeOverviewView.swift) · [分类实现](../../PhotoEarth/Features/Places/PlaceLibraryView.swift) · [到访与封面规则](../../rules/places-covers.md)
- 中文名相同或同样显示「地名待完善」时，依据稳定国家、城市或到访身份对照成员。同城归并和不同语言下的显示标题分别断言。 [国家与城市模型](../../PhotoEarth/Domain/Models/PlaceCollection.swift) · [离线地名验收](../WORLD_CITY_ATLAS_ACCEPTANCE_2026-11-21.md) · [大图库验收](../LARGE_LIBRARY_PERFORMANCE_FIXES_2026-11-21.md)
