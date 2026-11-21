# 在线配乐与 Apple Music

## 子功能

- 在线配乐可按分类开播，也可指定起播曲目。目录支持本机缓存与重试，音乐按需串流。在线服务暂不可用时，照片仍可放映。
- Apple Music 入口可连接账户。有目录播放能力时可从最近播放、资料库播放列表或搜索结果选择音乐。首次系统授权由用户主动进入 Apple Music 来源触发。
- 两个来源共用上一首、播放／暂停和下一首。开播前可以更换或关闭本场配乐，取消选曲时保留上一次的选择。退出放映会清空音频队列。

## 用户怎么进入

- 在放映开场页打开「选择配乐」，切换「在线配乐」或「Apple Music」。有本场配乐时再次打开会落在相应来源。
- 在线配乐可直接选分类，或向右进入曲目选一首。Apple Music 按界面连接后选歌。用页头关闭本场配乐，或按遥控器 Back 保留原配乐并返回开场页。放映中从底部控制栏向上进入右上角音乐面板。

## 用 XCTest 和真实音源怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 首次断网打开在线配乐，重试并返回。另走有目录缓存的路径。 | 冷启动给出重试或返回入口，缓存路径可显示分类并提示播放仍需网络；照片可以继续。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) · [目录实现](../../PhotoEarth/Features/Slideshow/OnlineSlideshowMusic.swift) |
| 开场选在线分类或指定歌曲，确认开播后切歌、暂停。 | 歌名和当前来源正确，音乐控制随播放状态更新。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 正在浏览其他来源或准备曲目时按 Back。 | 保留原配乐，焦点恢复到开场页的配乐入口。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 首次放映先打开在线配乐，再主动进 Apple Music；用签名真机验证账户与音频。 | 前两步保持未请求 Apple Music，主动连接才出现授权。具备目录播放能力时实际出声，退出后 App 的配乐停止。 [PrivateLibrarySlideshowUITests](../../PhotoEarthUITests/PrivateLibrarySlideshowUITests.swift) · [AppleMusicSlideshowTests](../../PhotoEarthTests/AppleMusicSlideshowTests.swift) |

## 容易验错的地方

- Apple Music 模拟器 fixture 检查授权状态、选曲路径与 Focus。真实订阅能力、串流和输出声音分别以签名 Apple TV 和实际音源为准。 [配乐规则](../../rules/slideshow.md) · [Apple Music 验收说明](../APPLE_MUSIC_SLIDESHOW_2026-09-15.md)
- 整场暂停、进入后台或开启且实际播放媒体原声时，配乐暂停并按场景恢复。检查应用状态的同时听实际输出。 [配乐入口实现](../../PhotoEarth/Features/Slideshow/SlideshowMusicSourceView.swift) · [控制层实现](../../PhotoEarth/Features/Slideshow/EarthSlideshowView.swift)
