# 操控地球与查看当前画面

## 子功能

- 首页的「滚动地球」把当前镜头交给直接操控。首页城市卡先转到目的地，再推近至普通地图。照片详情的小地球以当前照片的真实 GPS 开始新的探索。
- 触摸面拖动、方向键单击和长按都可转动地球。Play/Pause 打开缩放工具条，可放大、缩小、切换卫星或地图。指定城市可用「改看当前画面」解除城市范围。
- 自动底图以原生相机的 800 km 为双向交接点。放近显示普通地图和真实 GPS 照片图钉，拉远回到卫星和地点亮点。停稳后照片带更新；远景数量是代表照片数。
- 「设置 → 地球操作」可切换「显示地球操作提示」与「等待地球影像」。后者默认开启。影像迟迟未就绪时会自动揭开画面。

## 用户怎么进入

- 冷启动进入首页时默认聚焦「滚动地球」，按一次中键即可进入；也可选择一张城市卡。照片详情可选择左下角小地球。Apple TV 主屏也可选择 Top Shelf 首卡。
- 在直接操控场景按 Play/Pause 打开工具条，按 Back 回到地图。中键松开后查看当前城市墙或当前画面墙。

## 用 XCTest 和实体遥控器怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 从首页进入地球、开关缩放工具条，再按 Back。 | 进入时保持首页镜头，Play/Pause 不打开照片墙，关闭工具后可继续转动，返回恢复来源 Focus。 [PhotoEarthUITests](../../PhotoEarthUITests/PhotoEarthUITests.swift) |
| 选城市，拉近到街区再拉远，另用工具条手动切底图。 | 城市先对准再下沉，落点为普通地图。双向跨尺度可见对应图钉和底图，手动切换保持镜头。 [CityNavigationTests](../../PhotoEarthTests/CityNavigationTests.swift) · [GlobeScaleUITests](../../PhotoEarthUITests/GlobeScaleUITests.swift) |
| 进入城市后移动镜头，打开工具条选「改看当前画面」，再用中键开墙。 | 移动时城市范围提示仍在。显式切换后提示消失，中键打开当前画面墙，返回仍处于当前画面范围。 [ExperienceScopeUITests](../../PhotoEarthUITests/ExperienceScopeUITests.swift) |
| 在实体遥控器上慢拖、快扫、抬手重落、单击与持键。 | 按键和触控各处理一次，工具条方向键聚焦控件，触摸拖动仍移动地图。用实体屏幕核对卫星到街区的交接。 [Siri Remote 规则](../../rules/siri-remote.md) · [实体电视与模拟器记录](../JOURNEY_REFACTOR_ACCEPTANCE_2026-11-19.md) |

## 容易验错的地方

- 正式照片墙由中键松开时的原生地图投影或指定城市集合决定。地球底部照片带会等待停稳再刷新，远景只抽取屏内样本。 [主地球规则](../../rules/globe.md) · [照片范围](README.md#入口相似照片范围各有定义)
- 城市落点截图只证明最后底图。核对先转再推近，用有明显经度差的城市及过程证据。减少动态效果打开时直接到落点。原生影像冷启动和遥控器触面用真机验证。 [地球交互实现](../../PhotoEarth/Features/Globe/GlobeExperienceModel.swift) · [原生相机与底图实现](../../PhotoEarth/Rendering/Earth/MapKitEarthView.swift) · [近期模拟器验收](../LARGE_LIBRARY_PERFORMANCE_FIXES_2026-11-21.md)
