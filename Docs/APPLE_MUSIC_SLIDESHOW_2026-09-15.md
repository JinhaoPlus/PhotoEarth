# Photo Earth Apple Music 放映配乐实现记录

状态：代码与模拟器状态／Focus 流程完成；开发者后台 MusicKit App Service 和真实 Apple TV 订阅播放仍需人工验收

日期：2026-09-15

对应方案：[EARTH_SLIDESHOW_PRODUCT_PLAN_2026-09-14.md](EARTH_SLIDESHOW_PRODUCT_PLAN_2026-09-14.md)

## 1. 产品行为

- Apple Music 是可选增强。进入放映不会自动弹权限，也不会因为用户未订阅而阻断照片播放。
- 用户主动展开控制层并选择「连接 Apple Music」后，App 才调用 `MusicAuthorization.request()`。授权成功后再读取 `MusicSubscription.current.canPlayCatalogContent`；只有当前账户具备目录播放能力时才开放选歌。
- tvOS 没有采用系统音乐选择器。应用内选歌页展示最近播放、用户音乐资料库中的播放列表、最近播放歌曲，并可搜索 Apple Music 目录中的歌曲、专辑和播放列表。
- 用户选择歌曲、专辑或播放列表后，Photo Earth 创建独立的 `ApplicationMusicPlayer` 队列；不是简单跟随 Music App 当前正在播放的内容。控制层提供上一首、播放／暂停、下一首和更换配乐。
- 配乐只在当前放映会话内有效，退出即停止并清空。音乐 ID、搜索词、资料库内容和播放历史不写入 SQLite、UserDefaults、iCloud KVS 或照片索引，音乐文件也不会被下载、复制、导出或分享。
- 队列设置 `affectsListeningHistory = false`，避免一场照片放映改变用户的 Apple Music 推荐画像。
- 沉浸观看状态仍只显示无文字进度轨和左下角照片 GPS 小地球；歌曲信息和音乐按钮只在用户主动展开控制层时显示。
- 主播放操作为底部紧凑纯图标胶囊，背景音乐为右上角正方形面板。操作按钮不显示文字，但保留本地化 VoiceOver 名称；当前曲目封面裁切铺满整个面板，叠加顶部约 14%、中部 24%、底部 66% 的渐深半透明黑色遮罩，封面缺失或加载失败时显示中性黑灰渐变占位。面板不显示「背景音乐」文字标题，只在右上角保留低对比度灰白音符，容器继续提供本地化 VoiceOver 分组名称；画面保留当前歌名和作者。歌名或作者只在超宽时低速往返滚动，两端停留；Reduce Motion 下使用单行尾部截断。

## 2. 播放与声音仲裁

配乐与照片状态机保持松耦合：照片不会选择歌曲，也不会按歌曲节拍、歌词或指定时间点切换。用户选择音乐这一动作才发起流式播放，随后队列可自然连续播放。

音乐只在以下条件同时满足时播放：

- 用户已经选择音乐且没有手动暂停音乐；
- 整场放映处于运行而非暂停状态；
- 当前为可呈现阶段，App 位于前台；
- Live Photo／视频原声没有实际播放。

tvOS MusicKit 的应用播放器没有独立音量接口，因此不能可靠实现背景音乐降低音量的 ducking。用户打开本场原声后，动态媒体真正开始发声时暂停 Apple Music，结束或离开该媒体后恢复；本版不做双路混音或交叉淡化。全局 Play/Pause 仍控制整场放映，音乐跟随暂停和继续；进入后台、退出放映、订阅失效或权限失去时立即停播。

## 3. 代码结构

- `PhotoEarth/Features/Slideshow/AppleMusicSlideshow.swift`
  - `AppleMusicSlideshowController` 管理授权、订阅、浏览、搜索、用户播放意图和放映上下文仲裁。
  - `MusicKitSlideshowMusicDriver` 封装 MusicKit 请求与 `ApplicationMusicPlayer`，监听播放器状态和当前队列项；更换队列后会重绑观察，确保自动切到下一首时更新标题和封面。
  - Debug 参数 `--apple-music-fixture` 提供完全本地的订阅与曲目夹具，只用于稳定 UI 自动化。
- `PhotoEarth/Features/Slideshow/AppleMusicSelectionView.swift`
  - 提供适配 Siri Remote Focus 的电视选歌页、目录搜索、分区货架、加载／空／失败状态和准备反馈。
- `PhotoEarth/Features/Slideshow/EarthSlideshowView.swift`
  - 提供底部纯图标播放胶囊、以当前封面铺满并覆盖渐深透明遮罩的右上角方形音乐面板，以及超宽曲目信息往返滚动；同步整场暂停、动态媒体发声、Scene Phase、选歌页暂停恢复和退出清理。
- `PhotoEarth-Info.plist` 与 `PhotoEarth/InfoPlist.xcstrings`
  - 添加 `NSAppleMusicUsageDescription` 及 8 种语言用途说明。
- `PhotoEarth/Localizable.xcstrings`
  - 添加连接、订阅状态、选歌、搜索、播放控制和错误等 8 种语言文案。

## 4. 开发者后台前置条件

源码无需自建 Apple Music developer token。Apple 的原生 MusicKit 会在 App ID 开启 MusicKit App Service 后，按 bundle identifier 自动关联运行时服务。

发布或真机播放前必须完成：

1. 在 Apple Developer 的 Certificates, Identifiers & Profiles 中打开显式 App ID `com.doupi.PhotoEarth.PhotoEarth`。
2. 在 App Services 页签启用 MusicKit 并保存。
3. 如果使用手工签名，重新生成引用该 App ID 的 provisioning profile；自动签名则让 Xcode 刷新签名资产。
4. 在已登录 Apple Music 且具备有效订阅的真实 Apple TV 上，验证授权、搜索、歌曲／专辑／播放列表队列、跳歌和声音输出。

Apple 官方说明：

- [启用 MusicKit App Service](https://developer.apple.com/help/account/services/musickit)
- [MusicKit 自动生成 developer token](https://developer.apple.com/documentation/musickit/using-automatic-token-generation-for-apple-music-api)
- [MusicAuthorization.request 与用途说明要求](https://developer.apple.com/documentation/musickit/musicauthorization/request%28%29)
- [canPlayCatalogContent 的目录播放能力语义](https://developer.apple.com/documentation/musickit/musicsubscription/canplaycatalogcontent)
- [ApplicationMusicPlayer 是不影响 Music App 状态的 App 专属播放器](https://developer.apple.com/documentation/musickit/applicationmusicplayer)
- [MusicKit 队列的收听历史开关](https://developer.apple.com/documentation/musickit/musicplayer/queue/affectslisteninghistory)
- [修改 App ID capability 后更新 provisioning profile](https://developer.apple.com/help/account/identifiers/enable-app-capabilities)

## 5. 审核与版权边界

实现遵守 Apple 对 MusicKit 的核心要求：播放由用户主动发起，界面提供标准的播放、暂停和跳过控制，不额外收费或以广告变现 Apple Music 访问，不下载或分享音乐文件。照片切换与音乐时间线独立，也不输出包含 Apple Music 音频的视频文件。

这条边界很重要：Apple 明确说明，把特定歌曲安排在特定时刻或生成可分享的音视频，可能需要另外取得同步或改编权利。本版不实现这些能力。依据见 [App Review Guidelines 4.5.2](https://developer.apple.com/app-store/review/guidelines/#music)。

## 6. 自动化覆盖与未完成验收

- `PhotoEarthTests/AppleMusicSlideshowTests.swift` 覆盖不提前弹权限、显式授权、订阅／非订阅／临时失败、放映暂停与原声仲裁、订阅丢失、浏览搜索、播放器切歌元数据更新，以及退出时停止并清空应用队列状态。
- `PhotoEarthTests/LocalizationTests.swift` 覆盖 Apple Music 用途说明和 UI 文案的 8 种目标语言。
- `PhotoEarthTests/EarthSlideshowTests.swift` 覆盖歌名／作者短文本不滚动、超宽文本低速往返、首尾停留，以及 Reduce Motion 下静止并截断。
- `PhotoEarthUITests/EarthSlideshowUITests.swift` 使用本地 fixture 覆盖：从放映控制层连接、进入选歌页、选择播放列表、返回画面并出现右上角正方形音乐卡与底部纯图标播放栏，再通过 Back 退出放映并恢复照片墙。已复核 1920 × 1080 截图中的安全区、Focus、歌名与作者。
- 2026-09-15 最终完整 `PhotoEarthTests` 为 326 项、0 失败（含动态参数共 438 次通过）；Apple Music 订阅选歌与退出 UI 流程 1 条通过；tvOS 设备目标 Release 无签名构建通过。
- tvOS Simulator 只能证明 App 状态机、布局和控制流程，不能证明真实 Apple Music 账户授权或目录音频播放。[Apple 的 MusicKit 示例](https://developer.apple.com/documentation/musickit/integrating-musickit-into-your-app)也明确要求真机运行，因此真实 Apple TV 验收仍是发布前硬门槛。
