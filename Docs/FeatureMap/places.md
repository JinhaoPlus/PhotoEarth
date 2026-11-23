# 首页、最近到访、地点

## 子功能

- 侧边栏提供首页、最近到访、地点、那年今日和设置。首页保留卫星地球，首排展示最近到访的城市，向下按年份浏览更多城市。
- 最近到访每次访问一张卡，按访问结束月分组。同一城市去过多次时，可分别打开每次访问。
- 在「地点」里先选国家或地区，再选城市。城市照片墙按旅程列出日期、素材数和一行照片。一趟旅程里离开再回到同一城市，两次到访归在同一段。地名待完善的访问仍可浏览，保留真实 GPS。
- 「每次到访的最低数量」默认 10，可设为 1 至 1,000。最近到访按每次访问的可见定位素材数判断是否展示。首页和 Top Shelf 先筛达标访问，再选每城最近的一次做代表；从这两个入口打开的城市范围包含该城全部可见素材。「地点」按旅程展示时也包含低于门槛的到访。

## 用户怎么进入

- 打开侧边栏选「首页」，从「滚动地球」向下进入最近城市和年份货架。选城市后先进入该城市的地球探索。
- 选「那年今日」，在固定页头逐日切换，或打开月日选择器跳转。从今年起，每个年份保留一行位置，有素材时标题列出当天最先拍到的至多三个不同城市与国家或地区，右端可展开全部。点照片进入该年当天的详情，「放映这一天」串联所有年份。
- 选「最近到访」，从月份内选一张访问卡直达该次照片墙。
- 选「地点」，进入一个国家或地区后可选「查看所有照片」打开该范围的照片墙，也可选城市。选城市直接打开分段照片墙。按某段的「展开」在原位看其余照片，再按「收起」恢复一行。
- 首页、最近到访和「地点」向下浏览后，按 Back 先回页首。顶层页首再按交给原生侧边栏，国家或地区详情页首再按回到列表原卡片。
- 在「设置 → 照片与扫描」调整「每次到访的最低数量」。

## 用 XCTest 怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 换到前一天，用日期选择器回到今天。打开单项、左右翻阅并返回，展开和收起该年，再放映。 | 空年份保留灰色刻度。上下滚动时年份刻度与照片列的横向位置固定。返回到最后观看的素材，放映跨过空年进入更早年份。[那年今日遥控器用例](../../PhotoEarthUITests/OnThisDayUITests.swift) · [模拟器截图](../Evidence/2026-11-23/anniversary/) |
| 用遥控器走完首页、最近到访、地点和设置，分别打开所选国家或地区及其中一个城市的照片墙再返回。 | 回到原页面和原卡片。国家或地区详情页保留「查看所有照片」，页首 Back 退回原卡片。首页从城市探索退出回同一张城市卡。 [SidebarNavigationTests](../../PhotoEarthUITests/SidebarNavigationTests.swift) · [PhotoEarthUITests](../../PhotoEarthUITests/PhotoEarthUITests.swift) |
| 打开两趟旅程都到过的东京，其中一趟中途去了京都。 | 同一面墙中能看到两趟各自的日期和一行照片。展开新旅程后可看完整的两次东京到访，旧旅程仍保留一行。收起、打开单张及返回城市卡可用遥控器完成。[SidebarNavigationTests](../../PhotoEarthUITests/SidebarNavigationTests.swift) |
| 将首页、最近到访、国家或地区列表或其中的城市列表滚到下方，再按两次 Back。 | 第一下回页首，聚焦「滚动地球」、第一张卡或「查看所有照片」。第二下移到原生侧边栏或退回原卡片。 [OverviewScrollingUITests](../../PhotoEarthUITests/OverviewScrollingUITests.swift) · [SidebarNavigationTests](../../PhotoEarthUITests/SidebarNavigationTests.swift) · [RecentVisitFocusUITests](../../PhotoEarthUITests/RecentVisitFocusUITests.swift) |
| 从最近到访双列移动到中间只有一张卡的月份，再继续上下滚动。 | 中间月份能聚焦。上下往返经过宽幅封面时，同列卡片的焦点边缘仍与可见边缘对齐。同城的不同访问分别有自己的日期和封面。 [RecentVisitFocusUITests](../../PhotoEarthUITests/RecentVisitFocusUITests.swift) |
| 滚动大示例库，模拟慢图。 | 图片慢时卡片仍可聚焦，离开子页面再返回能恢复位置。 [OverviewScrollingUITests](../../PhotoEarthUITests/OverviewScrollingUITests.swift) |
| 修改最低素材数并重启，核对两次到访素材数不同的同城样本。 | 设置值能读回。首页、最近到访和 Top Shelf 按门槛更新，城市墙仍包含该城的可见素材。 [OverviewContentTests](../../PhotoEarthTests/OverviewContentTests.swift) · [JourneyScanGateTests](../../PhotoEarthTests/JourneyScanGateTests.swift) · [JourneyShelfTests](../../PhotoEarthTests/JourneyShelfTests.swift) |

## 容易验错的地方

- 首页城市卡显示的访问素材数、最近到访卡的独立范围、整座城市的照片墙总数各有口径。检查封面时同时核对代表访问和封面资产资格。 [首页实现](../../PhotoEarth/Features/Globe/GlobeOverviewView.swift) · [分类实现](../../PhotoEarth/Features/Places/PlaceLibraryView.swift) · [到访与封面规则](../../rules/places-covers.md)
- 中文名相同或同样显示「地名待完善」时，依据稳定国家、城市或到访身份对照成员。同城归并和不同语言下的显示标题分别断言。 [地点集合模型](../../PhotoEarth/Domain/Models/PlaceCollection.swift) · [离线地名验收](../WORLD_CITY_ATLAS_ACCEPTANCE_2026-11-21.md) · [大图库验收](../LARGE_LIBRARY_PERFORMANCE_FIXES_2026-11-21.md)
