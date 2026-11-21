# 照片墙、详情与媒体

## 子功能

- 固定集合墙和冻结当前画面墙按范围分页，标题与总数固定在滚动区外。照片按原比例排列，图片区可继续加载，详情可用左右键跨页浏览。
- 详情可查看媒体类型、拍摄时间、地点、GPS、尺寸、收藏或视频时长。真实 GPS 可用于左下角小地球，地址有当前资产的 Photos 缓存时显示。
- Live Photo 与视频先显示封面。中键、Play/Pause 或右下角播放控件可主动播放和暂停。iCloud 媒体加载显示进度，可取消或重试。

## 用户怎么进入

- 从首页城市探索、「滚动地球」或地图回看按中键。也可点最近到访卡、国家页的整个国家入口、城市卡或 Top Shelf 城市海报。各入口的成员范围见[功能地图](README.md#入口相似照片范围各有定义)。
- 在照片墙选一张照片进入详情。选择「更多操作」或向上打开控制层，查看信息、小地球和上一张／下一张。选小地球后进入临时探索，Back 回到该照片的纯观看画面。
- 详情有操作层时按 Back 收起；纯观看时 Back 返回墙上最后实际观看的照片。已向下滚动的墙按 Back 先回墙首，再按一次回来源。

## 用 XCTest 怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 使用混合横竖比例或有多页的照片墙，从第 48 张看至第 49 张，再反向浏览并退出。 | 图片顺序和比例保持，跨页出现正确的照片，返回把 Focus 放在最后实际观看的照片。 [ContinuousPhotoViewingTests](../../PhotoEarthUITests/ContinuousPhotoViewingTests.swift) · [OriginalPhotoRatioUITests](../../PhotoEarthUITests/OriginalPhotoRatioUITests.swift) |
| 从当前画面墙和国家分类墙分别进入某张照片的小地球。 | 新探索以该照片真实位置为锚点。退出新探索时恢复来源照片；再次按 Back 回到原墙，原分类和照片位置保持。 [PhotoGlobeNavigationTests](../../PhotoEarthUITests/PhotoGlobeNavigationTests.swift) |
| 打开 Live Photo 或视频详情，检查常驻播放入口，再播放、换片或离开。 | 打开详情先见封面。明确播放后才请求动态资源，换片或退出释放先前播放，迟到结果不能替换当前素材。 [ContinuousPhotoViewingTests](../../PhotoEarthUITests/ContinuousPhotoViewingTests.swift) · [PhotoMediaSupportTests](../../PhotoEarthTests/PhotoMediaSupportTests.swift) |

## 容易验错的地方

- 墙标题、准确总数、已加载的这一页和预览照片数需分别检查。当前画面计数进行中先显示计算状态。用不同来源入墙时，要确认成员范围和返回位置。 [墙实现](../../PhotoEarth/Features/PhotoViewer/ViewportPhotoWall.swift) · [集合墙实现](../../PhotoEarth/Features/PhotoViewer/CollectionPhotoWall.swift) · [照片浏览规则](../../rules/photo-browsing.md)
- 照片的真实 GPS 即使暂时没有城市名也可预览。测试地址只覆盖当前资产的 Photos 缓存。实际下载、Live Photo 声音和视频兼容性需用真实素材核对。 [详情实现](../../PhotoEarth/Features/PhotoViewer/PhotoDetailView.swift) · [地址用例](../../PhotoEarthTests/PhotoDetailAddressTests.swift) · [媒体说明](../LIVE_PHOTO_VIDEO_SUPPORT_2026-09-12.md)
