# PhotoEarth 用户动线

[PostHog 用户动线看板](https://us.posthog.com/project/756918/dashboard/2392004) 默认展示最近 30 天的正式版。要验收 TestFlight，将看板的 `build_channel` 改为 `testflight`。Debug 和模拟器关闭线上采集。

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

以下名称统一加 `photoearth_` 前缀。图库模式可区分个人图库、示例和公共地球。入口、结果及设置名均来自固定枚举。

| 事件 | 触发与字段 |
| --- | --- |
| `app_opened`、`foregrounded` | 主 App 启动；首次进入前台及从后台返回。临时中断恢复不计一次新的前台访问。 |
| `welcome_presented`、`sample_opened` | 首次连接欢迎页显示；进入示例图库。 |
| `photo_access_requested`、`photo_access_result` | 用户发起连接，示例内发起带 `library_mode=sample`；完成后记录 granted、denied 或 undetermined。 |
| `scan_scope_presented`、`scan_scope_dismissed` | 打开初始或设置中的扫描范围；初始范围页另外记录保存或关闭。 |
| `first_scan_requested`、`first_index_ready` | 确认初始范围并启动扫描；扫描期间首次提交索引，区分 ready 与 empty。 |
| `preparation_action`、`preparation_failed` | 请求更新、补地名、重建、暂停或继续；进入失败状态时仅上报准备任务类别。 |
| `home_presented`、`sidebar_selected` | 可见且处于前台的首页；侧边栏目的地改变。 |
| `top_shelf_opened`、`globe_explored` | 在主 App 接住地球或城市入口；进入可操控地球，带入口类别。 |
| `photo_wall_opened`、`wall_browsing_finished` | 打开照片墙，带入口和范围。退出时仅记 wall_only 或 viewed_details，每次墙访问最多一条结果。 |
| `map_review_opened` | 进入集合的地图回看。 |
| `slideshow_requested`、`music_picker_opened`、`slideshow_started` | 新场次请求；该场首次打开配乐选择；已有候选照片并真正进入开场。开场带范围和选定的配乐来源。 |
| `slideshow_finished` | 自然结束、开场前关闭、开场后关闭、失败退出或重新开始。停留分为不足 1 分钟、1 至不足 5 分钟、5 至不足 30 分钟、30 分钟及以上。 |
| `settings_changed` | 已变更的设置类别，包括扫描范围、途经过滤、最低素材数、主屏展示、地球提示和影像偏好。 |

公共字段为 `product`、`analytics_schema`、`app_version`、`app_build`、`build_channel`、`platform`、`os_version`、`system_language` 和 `app_language`。系统首选语言采用系统提供给此 App 的首选项，去掉地区并保留中文简繁。界面语言采用 App 实际解析出的本地化语言。SDK 在发送前清理未列出的属性，禁用 IP 地理解析和人物档案。

SDK 初始化、编码、缓存和发送均在后台。照片墙内部只在内存中保留是否看过详情，不保存照片信息或浏览张数。地球转动、遥控器焦点、照片切换、放映逐张播放与扫描进度不触发事件。实现与回归用例见[事件与后台队列](../../PhotoEarth/Services/ProductAnalytics.swift)和[统计测试](../../PhotoEarthTests/ProductAnalyticsTests.swift)。
