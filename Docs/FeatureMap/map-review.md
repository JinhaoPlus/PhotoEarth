# 地图回看

## 子功能

- 集合墙可打开地图回看，用来源集合全部成员的地理范围取景。进入后按地图当前画面读取可见照片。
- 聚合图钉以封面照片的真实 GPS 为锚点，角标显示聚合数量。底部胶片可先显示预览，准确总数与新图钉在同一视野统计完成后交付。
- 地图中键冻结当前画面并打开照片墙。在墙首按 Back 回到原地图。主地球的当前画面墙同样用 Back 回到原镜头。退出地图回看后恢复来源墙的范围、滚动和照片 Focus。

## 用户怎么进入

- 从最近到访、国家、分类城市或首页指定城市进入照片墙，选择「地图回看」。
- 进入后直接使用遥控器转动地图。Play/Pause 打开工具条，可缩放和切换底图；中键松开进入冻结墙。

## 用 XCTest 怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 分别从国家、分类城市和首页城市进入，再平移到来源之外。 | 初始镜头跟随各来源；平移后的范围跟随新画面。返回仍聚焦原墙的照片，首页城市墙仍沿用原城市范围。 [MapReviewUITests](../../PhotoEarthUITests/MapReviewUITests.swift) · [MapReviewTests](../../PhotoEarthTests/MapReviewTests.swift) |
| 在地图停稳后进入冻结墙，再按 Back。 | 地图只有一个实例；同一画面的图钉合计、稳定后的胶片总数和冻结墙总数一致。跨页查看详情后能逐层回原照片。 [MapReviewUITests](../../PhotoEarthUITests/MapReviewUITests.swift) · [GlobeScaleUITests](../../PhotoEarthUITests/GlobeScaleUITests.swift) |
| 平移到无照片的位置，再移动回来。 | 统计中与空状态有区别。确认空视野后只见简短提示；返回有照片的位置后出现新结果。 [MapReviewUITests](../../PhotoEarthUITests/MapReviewUITests.swift) |

## 容易验错的地方

- 原来源墙只负责初始镜头与返回。重新筛选使用当前原生画面，验证范围切换时要在新画面里放一个属于其他集合的对照资产。 [地图回看规则](../../rules/map-review.md) · [地图回看实现](../../PhotoEarth/Features/PhotoViewer/MapReviewView.swift)
- 移动期间原生图钉可能保留上一完整批，旧胶片和总数已经失效。等新统计完成再比较计数。 [地图回看规则](../../rules/map-review.md) · [近期地图验收](../LARGE_LIBRARY_PERFORMANCE_FIXES_2026-11-21.md)
