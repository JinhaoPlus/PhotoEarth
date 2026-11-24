# PhotoEarth 用户动线

[PostHog 用户动线看板](https://us.posthog.com/project/756918/dashboard/2392004) 默认展示最近 30 天的正式版。看板与现有图表查询均带 `build_channel=release`，未限定埋点版本。验收 TestFlight 时可在事件流按 `build_channel=testflight`、`analytics_schema=3` 筛选。Debug 和模拟器关闭线上采集。

| 看板问题 | 统计口径 |
| --- | --- |
| 有多少安装在使用、过一周还会回来吗？ | 进入前台按安装去重得到 DAU。按首次观察到进入前台的周分组，计算后续各周的回访。 |
| 用户在哪里完成或放弃首次连接？ | 欢迎页 → 请求权限 → 获得权限 → 确认扫描 → 首次索引有可浏览素材 → 个人图库首页，窗口 7 天。单独列出拒绝、关闭初始范围页、空索引和准备失败。 |
| 示例有没有让用户体验到价值、连接自己的图库？ | 一条漏斗看 1 天内从欢迎页进入示例首页和示例照片墙，另一条看 7 天内从示例发起连接并到达个人图库首页。 |
| 用户从哪里进入浏览、有没有深入看？ | 分入口看照片墙覆盖的安装数，分图库模式看首页、探索、墙、回看和放映。每次退出墙时汇总是否打开过详情。Top Shelf 单列主 App 成功接住的入口。 |
| 放映能否开播，用户何时退出？ | 请求和实际进入开场组成 1 天安装漏斗。结束原因、停留时长档和开场配乐按场次计数。停留从请求到结束，包含准备、暂停及后台时间。 |
| 哪些版本、语言正在使用？ | 按 App 版本或系统首选语言拆分活跃安装。其他图可用公共字段进一步筛选。 |

安装按本地匿名标识去重。同一安装可以进入多个功能或入口。漏斗按同一安装顺序匹配，允许跨尝试。已授权后直接进入首页的安装计入活跃与功能覆盖。进程被终止、撤回统计或队列积压时可能缺少事件，尤其是退出事件。周留存以这版埋点能观察到的首次前台为起点。

## 事件字典

当前代码使用 `analytics_schema=3`。以下名称统一加 `photoearth_` 前缀。图库模式可区分个人图库、示例和公共地球。入口、结果及设置名均来自固定枚举。

| 事件 | 触发与字段 |
| --- | --- |
| `app_opened`、`foregrounded` | 主 App 启动；首次进入前台及从后台返回。临时中断恢复不计一次新的前台访问。 |
| `welcome_presented`、`sample_opened` | 首次连接欢迎页显示；进入示例图库。 |
| `photo_access_requested`、`photo_access_result` | 用户发起连接，示例内发起带 `library_mode=sample`；完成后记录 granted、denied 或 undetermined。 |
| `scan_scope_presented` | 打开扫描范围。`origin` 区分首次连接 initial、设置 settings、扫描准备页 preparation、空图库 emptyLibrary。 |
| `scan_scope_dismissed`、`scan_scope_edit_finished` | 前者统计首次范围页的 saved 或 dismissed。后者统计再次编辑的 saved（保存了变动）、unchanged（原样保存）或 dismissed。两者均带打开来源。 |
| `first_scan_requested`、`first_index_ready` | 确认初始范围后启动扫描，同一次连接在本次运行中首次发布索引时记 ready 或 empty。后续调整范围触发的重扫单独统计。 |
| `preparation_action`、`preparation_completed`、`preparation_failed` | 主动请求更新、补地名、重建、暂停、继续、提前浏览或切换发现地点时的镜头跟随。后台作业正常结束或失败时记录实际模式 initial、update、labels 或 rebuild，包含自动检查。 |
| `home_presented`、`sidebar_selected`、`country_opened` | 进入前台首页、切换侧边栏目的地、在「地点」选国家或地区进入城市列表。 |
| `top_shelf_opened`、`globe_explored`、`globe_action` | 主 App 接住城市或地球深链；进入可操控地球；打开缩放工具条、切换底图或从指定城市改看当前画面。地图回看的操作带 entry=mapReview。 |
| `photo_wall_opened`、`wall_browsing_finished` | entry 指明最近到访、地点列表、首页城市、详情小地球、地球、Top Shelf 或地图回看。scope 区分 recentVisit、city、country、collection、currentView。退出每次墙访问时汇总 wall_only 或 viewed_details，保留同一入口与范围。 |
| `wall_action`、`detail_playback_requested` | 主动切换拼贴或原比例、展开城市内的一趟旅程。一次连续详情浏览中，用户主动操作视频与 Live Photo 播放各最多一条，表示播放请求。 |
| `map_review_opened` | 进入集合的地图回看。圈定画面打开的下一面墙带 entry=mapReview、scope=currentView。 |
| `anniversary_action` | 那年今日确认选日、回到今天、查看相邻日期、获准后展开年份。跨年放映走放映事件，scope=anniversary。 |
| `slideshow_requested`、`slideshow_started`、`slideshow_content_ready` | 新场次请求 → 有候选素材并进入开场 → 首次收到单张内容就绪或拼贴图块可见回调。每场各最多一次，可定位开场后仍未见内容的流失。 |
| `slideshow_action` | 同一场内每类操作最多一次。包括打开旅程选择、筛选、批选、应用全部或指定范围、暂停或继续、胶片选片、跳段、原声、配乐播放控制及重试。重播作为新场次记 replay。 |
| `music_picker_opened`、`music_picker_result` | 每场首次打开选择器带 stage=opening 或 playback。每次明确确认或返回记 confirmed 或 cancelled。确认同时带 music_source=none、online 或 appleMusic，以及 choice=off、recommended、category、track 或 appleMusic。 |
| `music_availability` | 在线目录加载结果 ready、cached 或 unavailable。用户主动连接 Apple Music 的结果 ready 或 unavailable。此结果描述选择器可用性，音频播放另由播放器负责。 |
| `slideshow_finished` | 结束原因、范围、最后确认的配乐来源及从请求到结束的时长档。原因包括自然结束、开场前后关闭、失败退出或重新开始。时长档为不足 1 分钟、1 至不足 5 分钟、5 至不足 30 分钟、30 分钟及以上。 |
| `free_journey_selected`、`offer_presented` | 首次确定免费旅程，以及付费操作或设置内实际出现购买面板。origin 区分集合墙、地球墙、那年今日、放映和设置。 |
| `store_requested`、`store_result` | 用户主动请求后记录 operation=trial、lifetime 或 restore 和入口。试用／买断区分已验证完成、取消、待处理或失败；恢复区分已验证可用权益、当前无可用权益、取消或失败。pending 表示此次请求的即时结果。 |
| `settings_changed`、`settings_reference_opened` | 保存后区分排除相册和相机筛选变动，以及途经过滤、最低素材数、主屏展示、地球提示、影像等待、默认配乐。展开扫描详情、查看隐私政策和在线配乐署名单列。 |

### 用新版事件分析功能

- 照片墙按 `entry × scope` 拆分，看各入口的访问次数，再按同样维度查看退出墙时的 `result`。能区分从首页城市进入的城市墙与改看当前视野后的墙。
- 放映把请求、开场、首屏内容就绪串成漏斗。按 `scope` 比较整库、到访、国家、城市、画面和那年今日。看旅程筛选、换配乐等行为的使用率时，按场次或去重安装选择分母。
- 付费选项展示 → 发起请求 → 商店即时结果，按相同 `origin` 和请求的 `operation` 分析。设置可能显示在试用期间。恢复成功只表示重新核验到可用权益。收入与最终交易以 StoreKit 为准。
- 现有看板覆盖基础动线。上述新增事件可在 PostHog 的 Trends 或 Funnels 中按事件字典查询。

公共字段为 `product`、`analytics_schema`、`app_version`、`app_build`、`build_channel`、`platform`、`os_version`、`system_language` 和 `app_language`。系统首选语言采用系统提供给此 App 的首选项，去掉地区并保留中文简繁。界面语言采用 App 实际解析出的本地化语言。SDK 在发送前清理未列出的属性，禁用 IP 地理解析和人物档案。

SDK 初始化、编码、缓存和发送均在后台。照片墙内部只在内存中保留是否看过详情，不保存照片信息或浏览张数。地球转动、遥控器焦点、照片切换、放映逐张播放与扫描进度不触发事件。实现与回归用例见[事件与后台队列](../../PhotoEarth/Services/ProductAnalytics.swift)和[统计测试](../../PhotoEarthTests/ProductAnalyticsTests.swift)。
