# 在线配乐与 Apple Music

## 子功能

- 首栏「推荐」从各类在线配乐抽歌，本场顺序固定。首次从现有九类各取两首，此后按这台电视最近主动点歌的原分类调整权重，并优先选近期没播过的曲目。点分类从第一首开播，向右可选具体曲目。

- 在线配乐可按分类开播，也可指定起播曲目。右侧按五列浏览封面，长曲名最多显示两行并在末尾省略。网格和播放面板显示同一张按原分类风格和曲名生成的封面。目录支持本机缓存与重试，音乐按需串流。在线服务暂不可用时，照片仍可放映。
- Apple Music 入口可连接账户。有目录播放能力时可从最近播放、资料库播放列表或搜索结果选择音乐。首次系统授权由用户主动进入 Apple Music 来源触发。
- 开播前和放映中都可以更换配乐、关闭配乐或恢复自动推荐，取消选曲时保留上一次的选择。音乐面板提供上一首、播放／暂停和下一首。退出放映会清空音频队列。

## 用户怎么进入

- 「设置 → 背景音乐」可调整新放映的自动配乐，查看两种来源与在线曲目署名。电视可离线阅读随版本提供的版权记录，每首列出曲名、作者和来源网站。

- 首页和照片墙放映默认从本场推荐第一首起播，按「开始放映」即可。开场准备音乐时保持安静，断网可继续放映。关闭配乐在本机跨场保留，暂停只对本场有效。
- 在开场页打开配乐按钮，切换「在线配乐」或「Apple Music」。有本场配乐时再次打开会落在相应来源。开场确认选曲后焦点回到「开始放映」，取消则回到配乐入口。
- 纯画面中按一次上键，显示完整控制层并聚焦右上角的更换配乐图标。无配乐时聚焦「选择配乐」。打开选曲页时停在当前画面，返回后恢复原播放或暂停状态。
- 在线配乐可直接选分类，或向右进入曲目选一首。Apple Music 按界面连接后选歌。用页头关闭配乐，或按遥控器 Back 保留原配乐并返回。

## 用 XCTest 和真实音源怎么验

| 场景 | 看到什么才算通过 |
| --- | --- |
| 从首页或城市墙直接开始，进入推荐页核对首曲和下一首，再关闭配乐并重启 App。 | 首曲和曲序与推荐页一致。关闭后可安静开播，选择「推荐」后恢复播放。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 首次断网打开在线配乐，重试并返回。另走有目录缓存的路径。 | 冷启动给出重试或返回入口，缓存路径可显示分类并提示播放仍需网络；照片可以继续。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) · [目录实现](../../PhotoEarth/Features/Slideshow/OnlineSlideshowMusic.swift) |
| 开场选在线分类或指定歌曲，从纯画面按一次上键。 | 焦点直达更换配乐，已有配乐时显示完整音乐面板并可单独暂停音乐。再次选曲时标记使用中的来源和曲目。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 开启原声后播放带音轨和无音轨的视频，再试 Live Photo。 | 带音轨的视频实际开始播放或 Live Photo 收到开播回调后，在线配乐降音量并继续播放，Apple Music 暂停。原声结束后在线配乐恢复音量，Apple Music 续播。无音轨和视频缓冲期间用常态音量。用真实素材和电视扬声器确认听感。 [PhotoMediaSupportTests](../../PhotoEarthTests/PhotoMediaSupportTests.swift) · [AppleMusicSlideshowTests](../../PhotoEarthTests/AppleMusicSlideshowTests.swift) |
| 放映中换配乐，再试播放中和暂停时返回。 | 更新选曲或保留原配乐，画面、播放状态与配乐入口焦点恢复。 [EarthSlideshowUITests](../../PhotoEarthUITests/EarthSlideshowUITests.swift) |
| 首次放映先打开在线配乐，再主动进 Apple Music；用签名真机验证账户与音频。 | 前两步保持未请求 Apple Music，主动连接才出现授权。具备目录播放能力时实际出声，退出后 App 的配乐停止。 [PrivateLibrarySlideshowUITests](../../PhotoEarthUITests/PrivateLibrarySlideshowUITests.swift) · [AppleMusicSlideshowTests](../../PhotoEarthTests/AppleMusicSlideshowTests.swift) |

## 容易验错的地方

- Apple Music 模拟器 fixture 检查授权状态、选曲路径与 Focus。真实订阅能力、串流和输出声音分别以签名 Apple TV 和实际音源为准。 [配乐规则](../../rules/slideshow.md) · [Apple Music 验收说明](../APPLE_MUSIC_SLIDESHOW_2026-09-15.md)
- 整场暂停或进入后台时，两种配乐均暂停并按场景恢复。媒体原声由各来源按上述规则处理。检查应用状态的同时听实际输出。 [配乐入口实现](../../PhotoEarth/Features/Slideshow/SlideshowMusicSourceView.swift) · [控制层实现](../../PhotoEarth/Features/Slideshow/EarthSlideshowView.swift)
