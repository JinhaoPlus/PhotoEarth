# 放映

## 子功能

- 首页播放整个可见合格图库，照片墙播放打开时的固定范围。最近的旅程先播，每趟按实际到访顺序播放，每次到访内依拍摄时间播放入选照片。
- 国家墙保留该国的各站。城市墙只放这座城市的各次到访。同一旅程中再次回到这座城市时以日期提示，进入另一段旅程时更新段号和日期范围。
- 放映按页选片并对近似重复素材去重。静态照片按原构图播出；Live Photo 和短视频可播放动态画面。原声由观众为本场开启。
- 暂停时出现控制层与相邻照片缩略图，可选片并保持暂停。继续时收起缩略图，退出后恢复来源页面和 Focus。
- 遥控器 Back 逐层退出配乐选择、放映控制层和纯放映画面。准备、失败或播完时按 Back 回到来源。

## 用户怎么进入

- 在首页选择「放映」，或在最近到访、国家、城市、当前画面及地图回看的照片墙选择「放映」。进入开场页后可直接「开始放映」，也可先「选择配乐」。
- 放映中可看到当前是本场第几段旅程。中键展开控制层，「下一段旅程」直接跳到下段开头，暂停时跳段会保持暂停。按 Play/Pause 暂停或继续，左右切片。暂停后向下进入缩略图条，中键选片。Back 先收起控制层，再退出到来源。

## 用 XCTest 怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 同一国家有两段旅程，新旅程内两次回到同一座城市。 | 国家墙依次播各站再进旧旅程，城市墙只出现该市素材。播放和暂停中可见段号与时期，暂停跳到最后一段后仍可继续，末段收起跳段按钮。 [放映端到端用例](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 从首页与不同范围的墙开播，暂停、选片，再退出。 | 无配乐时可开始。暂停选择后仍暂停；退出回到原来源。地图回看的墙恢复原先聚焦的照片。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 用竖图和含后续页面的示例播放。 | 竖图完整适屏。有合格素材时能越过首批继续；已播只记录实际展示项，选片不改变来源墙总数。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) · [EarthSlideshowTests](../../PhotoEarthTests/EarthSlideshowTests.swift) |
| 使用授权的真实图库做长播，核对实际呈现与来源范围。 | 放映持续推进，所播素材在来源范围内。图库资格变化、回到前台和动态媒体声音分别验。 [PrivateLibrarySlideshowUITests](../../PhotoEarthUITests/PrivateLibrarySlideshowUITests.swift) · [一小时实体电视验收](../JOURNEY_REFACTOR_ACCEPTANCE_2026-11-19.md#一小时连续放映) |

## 容易验错的地方

- 照片墙成员可能多于本场选片，选片只影响本场。分别核对来源范围、选片和实际展示。删除、撤权或相册排除需影响正在展示和待播项。 [放映规则](../../rules/slideshow.md) · [播放协调器](../../PhotoEarth/Features/Slideshow/EarthSlideshowCoordinator.swift)
- 首张照片出现只证明开场。验长播还要经过分页、跳过暂不可用素材、退出释放和 Focus 恢复。 [近期模拟器验收](../LARGE_LIBRARY_PERFORMANCE_FIXES_2026-11-21.md) · [配乐](music.md)
