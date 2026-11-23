# Photo Earth 中英文案审查

2026-11-23。按当前工作区核对了主 App、Apple TV 主屏幕扩展的四份 String Catalog，共 398 个条目，其中 395 个需要翻译。逐项对照了简中、繁中和英文，并沿 Swift 调用点检查同一流程的入口、状态、按钮和 VoiceOver 文案。另核对了权限弹窗的英文后备文案、仓库内的在线配乐分类名。其余五种语言均有对应条目，本轮未逐句审校。结论来自源码和资源，未实测电视上的换行或 VoiceOver 播报时长。

**处理进度**　以下 22 项中，购买页和购买前示例的两项按产品安排留待购买流程定稿。其余 20 项已落实到界面、权限用途说明和对应语言资源。下表保留审查时的原文，便于对照。

## 优先改会影响判断的文案

| 用户在哪里遇到 | 现在会读到什么 | 建议 |
| --- | --- | --- |
| [购买页](../PhotoEarth/Features/Onboarding/PurchaseGate.swift) | 当完整版价格已取得、试用商品尚不可用时，正文仍显示「免费体验 7 天」，页面只有买断、重试等按钮。英文同样承诺七天体验。 | 正文和试用按钮共用同一条件。此时写「试用暂不可用。你可以重试，或以 %@ 买断完整版。」／“The trial is currently unavailable. Try again or unlock the full version for %@.” 试用可用时保留期限、买断价格和不会自动扣费三项信息。 |
| [购买前的示例旅程 → 设置](../PhotoEarth/Features/Settings/SettingsView.swift) | 「连接我的照片图库」／“Connect My Photos” 在这个入口只关闭示例，用户回到购买页。在已取得使用权限的示例中，同一个按钮才会发起照片连接流程。 | 购买前的示例写「返回购买选项」／“Back to Purchase Options”。可以发起授权的入口沿用欢迎页的「连接照片图库」／“Connect Photo Library”。 |
| [设置 → 到访门槛](../PhotoEarth/Features/Settings/SettingsView.swift) | 标题「旅程最低素材数」，说明却是「每次到访至少有这么多……」。英文标题 “Minimum Items per Visit” 与实际筛选一致。一趟旅程可以包含多次到访。 | 标题「每次到访的最低数量」／“Minimum Items per Visit”。说明「按每次到访中带定位的照片和视频总数筛选。适用于首页、最近到访和 Apple TV 主屏幕。」把「1–1,000」放在自定数量输入框旁。见[筛选条件](../PhotoEarth/Domain/Models/PlaceCollection.swift)。 |
| [最近到访 → 没有达标结果](../PhotoEarth/Features/Places/PlaceLibraryView.swift) | 标题说「还没有旅行地点」，下面却说明已有到访，只是都没有达到门槛。英文也同时出现 “No Travel Places Yet” 和 “No visits meet the minimum.” | 标题改为「没有符合条件的到访」／“No visits meet the minimum”。下方只放恢复动作「在设置中调低每次到访的最低数量。」／“Lower the minimum in Settings.” 途经过滤造成的空列表也应使用对应原因。 |
| [扫描完成 → 没有符合条件的内容](../PhotoEarth/Domain/Models/LibraryPreparation.swift) | 「目前可访问的照片和视频中没有位置信息」比扫描结果能证明的范围更广。即使原片有位置，也可能因为被排除的相册、缺拍摄日期或相机信息设置而没被纳入。 | 「当前扫描范围内没有符合条件的照片或视频。请检查扫描范围和拍摄地点。」／“No photos or videos matched this scan. Check the scan scope and the locations in Photos.” 见[纳入条件](../PhotoEarth/Services/PhotoLibrary/TravelScanPolicy.swift)。 |
| [地球 → 底部照片预览](../PhotoEarth/Features/Globe/MemoryPhotoStrip.swift) | 只有确认总数为零时才显示「当前画面内没有找到照片」。预览为空、总数未知或大于零时却写「当前画面暂无可展示照片」，两句很难区分。英文已经区分 photos 和 previews。 | 有准确零计数时写「当前画面没有照片」。其余预览为空时写「暂无照片预览」／“No previews available”。繁中相应使用「目前畫面沒有照片」和「暫無照片預覽」。 |
| [从首页或照片墙开始放映](../PhotoEarth/Domain/Models/EarthSlideshowModels.swift) | 两个入口共用空结果提示「这个照片墙里没有可播放的回忆」／“No playable memories are available in this photo wall.” 从首页选旅程进入时，用户没有打开过照片墙。 | 两个入口都可用「这次放映没有可播放的照片或视频。」／“No photos or videos are available for this slideshow.” 见[首页与墙的放映范围](../PhotoEarth/Features/Globe/GlobeView.swift)。 |
| [扫描范围 → 读相册或保存失败](../PhotoEarth/Features/Settings/TravelScanScopeView.swift) | 初次读取相册失败和点保存失败，都显示「暂时无法读取所选相册，请重试」。第一次可能还没选过相册，保存失败时也不知道设置是否生效。 | 读取时写「无法载入相册列表。」／“Couldn’t load your albums.”，当前路径可提示重新打开扫描范围。提交失败时写「未能应用扫描设置，请重试。」／“Couldn’t apply your scan settings. Try again.” |
| [Apple Music 权限弹窗](../PhotoEarth/InfoPlist.xcstrings) | 「仅当你为放映选择背景音乐时……」把触发条件写成整个配乐功能。界面默认可以浏览在线配乐，主动选择 Apple Music 来源才进入它的授权流程。 | 用途写为「允许 Photo Earth 访问 Apple Music，以便为放映选择和播放音乐。」／“Allow Photo Earth to access Apple Music to choose and play music for your slideshow.” 同步[英文后备文案](../PhotoEarth-Info.plist)。见[配乐来源切换](../PhotoEarth/Features/Slideshow/SlideshowMusicSourceView.swift)。 |

## 同一个意思在不同地方怎么说

| 场景 | 不一致的地方 | 推荐用词 |
| --- | --- | --- |
| 首页城市、侧边栏、主屏幕设置 | 首页「最近抵达的城市」，设置「显示最近到访的城市」，英文两处都用 “Recently Visited Cities”。繁中设置说明还把侧边栏的「最近到訪」写成了「最近造訪」。主屏扩展的权限说明称其为「最近旅程的预览」。 | 首页城市货架用「最近到访的城市」／「最近到訪的城市」／“Recently Visited Cities”。侧边栏保留「最近到访」／“Recently Visited”，因为那里展示每一次到访。扩展权限说明写「在 Apple TV 主屏幕上显示最近到访城市的封面照片」。[首页](../PhotoEarth/Features/Globe/GlobeOverviewView.swift) · [扩展权限说明](../PhotoEarthTopShelf/InfoPlist.xcstrings) |
| 照片墙、扫描结果和详情的数字 | 混合照片和视频的列表使用「N 张照片」／“N photos”，进详情后却能看到「视频」。门槛说明又明确两者都计数。例如，只有视频的一组也可能被标成照片。 | 混合列表在标题已经说明内容时用「共 N 项」／“N items”；单种媒体且类型已知时用「N 张照片」「N 个视频」。不要为显示文案额外扫描图库。[计数格式](../PhotoEarth/App/AppLocalization.swift) · [照片墙的视频标记](../PhotoEarth/Features/PhotoViewer/ViewportPhotoWall.swift) |
| 放映的已选列表和搜索结果 | “No trips to show” 与「没有符合条件的旅程」共用在两种情况。用户在「已选」里取消最后一项，并没有搜索任何内容。 | 已选列表用「尚未选择旅程」／“No trips selected”。搜索或筛选无结果用「没有符合条件的旅程」／“No matching trips”。[旅程选择器](../PhotoEarth/Features/Slideshow/SlideshowJourneyPicker.swift) |
| 放映的暂停与继续 | 放映的遥控器朗读提示说「按播放/暂停键暂停放映」／“Play/Pause pauses the slideshow.” 同一按键也能恢复播放。 | 「左右键切换，上键显示控件，播放/暂停键暂停或继续。」／“Press left or right to skip, up for controls, or Play/Pause to pause or resume.” [按键与提示](../PhotoEarth/Features/Slideshow/EarthSlideshowView.swift) |
| 主地球与地图回看 | 主地球会根据输入设备选择触控或方向键提示。地图回看始终显示「拖动」，VoiceOver 也始终朗读整段触控说明，包括在没有触控输入的情况下。 | 两处沿用同一套设备判断。回看控件名称用「地图回看」／“Photo Map”，方向键、触控和中键的具体操作放在提示里。[主地球](../PhotoEarth/Features/Globe/GlobeExploreChrome.swift) · [地图回看](../PhotoEarth/Features/PhotoViewer/MapReviewView.swift) |
| 放映、配乐、原声 | 繁中按钮用「開始放映」，相册排除说明和使用统计说明却称「幻燈片」。英文同一配乐按钮在目录内是 “Choose Music”，Swift 后备文字写成 “Choose Soundtrack”。 | 繁中功能名称统一为「放映」。英文按钮保留 “Choose Music” 和 “Change Music”，同步后备文字。保留「原声」与「配乐」的区别，两个开关作用不同。[放映控件](../PhotoEarth/Features/Slideshow/EarthSlideshowView.swift) · [主文案目录](../PhotoEarth/Localizable.xcstrings) |

## 可以直接写短的地方

| 位置 | 原文 | 建议中英文 |
| --- | --- | --- |
| [首页与地点列表分页](../PhotoEarth/Features/Globe/GlobeOverviewView.swift) | 首页 “Unfold More Places”，地点列表 “Show More Places”；中文分别写「展开更多地点」和「显示更多地点」。 | 两处都用「显示更多地点」／“Show More Places”。 |
| [照片墙标题、等待与分页](../PhotoEarth/Features/PhotoViewer/ViewportPhotoWall.swift) | 胶片带叫「画面内的照片」，按中键后变成「当前画面中的回忆」，接着又是「正在展开回忆……」「展开更多回忆」。英文也从 photos 换到 memories。 | 墙标题「画面内的照片」／“Photos in This View”，分页「显示更多」／“Show More”，等待「正在载入…」／“Loading…”。单张详情复用了同一个等待文本，可以写得更具体，如 “Loading photo…”。 |
| [重新扫描](../PhotoEarth/Features/Settings/SettingsView.swift) | 设置按钮 “Rebuild Travel Index”，下一屏 “Rediscovering the paths in your photos while keeping known place names.” 中文是「重新寻找照片里的足迹，同时保留已有的地点名称」。 | 按钮「重新扫描照片和视频」／“Rescan Photos and Videos”。下一屏已有扫描阶段标题，说明只保留「已有地名会保留。」／“Existing place names are kept.” |
| [部分地名未确定](../PhotoEarth/Domain/Models/LibraryPreparation.swift) | 标题 “Place Preparation Complete for Now”／「本轮地点整理已完成」，下方又说还有 N 个地名待补充，第三行再解释部分城市或国家不确定。 | 标题「部分地名尚未确定」／“Some place names are unavailable”。下面给数量和用户关心的结果「这些照片仍可浏览。」／“You can still browse these photos.” |
| [放映退出确认](../PhotoEarth/Features/Slideshow/EarthSlideshowView.swift) | 「退出放映？」＋「留在放映中」＋「退出放映」。英文也连续三次出现 slideshow。 | 标题保留，按钮用「取消」「退出」／“Cancel”, “Exit”。原先已暂停的用户也能准确理解「取消」的结果。 |
| [在线配乐加载失败](../PhotoEarth/Features/Slideshow/SlideshowMusicSourceView.swift) | 普通失败状态有「请重试，或按返回键」，下方紧接「重试」。断网状态也显示同样结构。 | 普通失败省去这一行。断网时保留「恢复网络连接后可播放配乐。」／“Reconnect to play music.”，页面继续提供重试按钮。 |
| [扫描范围](../PhotoEarth/Features/Settings/TravelScanScopeView.swift) | 「同一素材出现在多个相册时，也会一并排除」容易让人误以为其他相册也会被排除。 | 「勾选要排除的相册。里面的照片和视频即使也在其他相册中，仍会隐藏。」／“Select albums to exclude. Their photos and videos stay hidden even if they also appear in other albums.” |

目录里还有「按你喜欢的方式，重温走过的世界」「只属于你的世界」「更多精彩时刻等待被发现」。当前设置页和照片墙没有找到这三条的显示调用；单改它们不会改变用户看到的界面。相反，购买页的「不会自动扣费」、主屏幕说明里的「第一排」、拒绝照片权限后的系统设置路径，以及扫描说明里的跨相册排除规则，都直接影响用户决定，建议保留。
