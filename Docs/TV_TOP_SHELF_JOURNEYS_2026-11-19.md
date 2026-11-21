# Apple TV 主屏的最近到访

照片地球位于 Apple TV 主屏第一排且图标获得焦点时，tvOS 可向 `PhotoEarthTopShelf.appex` 请求动态内容。它复用 App 首页「最近抵达的城市」的目的地选择，按最近一次到访排序，同一城市只保留一张。前五张与首页 Dock 对齐，继续向右浏览更早到访的城市。系统以一次发布取得整排内容，Photo Earth 将城市卡上限设为 24 张，以限制共享数据和封面准备时间。两处使用同一套城市身份、同一最新访问兜底与城市美学选片。点击城市海报直接进入首页对应城市的照片墙。侧栏「最近到访」独立列出每一次访问。

「旅程最低素材数」默认 5，与 LensPin 一致，可在「设置 → 照片与扫描」设为 1 至 1,000。门槛按每一次到访的可见定位照片和视频计算。首页与 Top Shelf 先筛选达标的到访，再从每座城市选最近一次作为卡片。达标后打开该城市的照片墙，墙仍保留该城市所有可见照片。侧栏「最近到访」用同一门槛，继续按次显示。修改数值时复用现有索引，并刷新 Top Shelf。

第一张为 16:9 原生 MapKit「滚动地球」，随后是同高 2:3 城市海报。最前五张已发布封面的拍摄坐标用来在首卡绘制地点亮点，个性地球准备期间可使用公共 MapKit 图。至少一张真实海报可读时才显示整排。新装、关闭、撤权、快照失效或整排封面不可用时，扩展返回 nil。开关默认开启，桌面刷新由 tvOS 调度。[Apple 主屏设计指引](https://developer.apple.com/design/human-interface-guidelines/top-shelf) · [TVServices 分区内容](https://developer.apple.com/documentation/tvservices/tvtopshelfsectionedcontent)

## 谁可以读取哪些内容

主 App 与扩展使用签名授权的共享钥匙串。两者保留各自原有的默认访问组，并显式加入同一个 `$(AppIdentifierPrefix)com.doupi.PhotoEarth.RecentJourneys` 访问组。共享项禁止同步并采用仅本机可用的访问等级。目录含至多 24 个标题、结束日期、路线摘要、封面资产引用、资格摘要和 Photos 历史标记，上限为 16 KiB。个性化地球另占一项，上限 192 KiB。每张预备海报占一项，上限 48 KiB，最多 24 项。地图和海报均用图库历史标记、当前扫描范围和封面资格摘要绑定；关闭私人展示时清除目录与图片。原有 SQLite 库仍在主 App 的私有容器。扩展仅读取钥匙串和 PhotoKit，不能修改系统图库。本次开发构建使用本机已有 tvOS provisioning profiles，其授权的团队钥匙串访问组同时覆盖两个签名目标。[Apple 钥匙串共享](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps) · [共享数据格式](../PhotoEarthTopShelfShared/JourneyShelfSnapshot.swift)

主 App 可以复用同一索引及扫描范围内已核验的封面。首次评估时先显示高斯模糊占位，得到评分结果后显示选中的照片，评估无结果时用代表访问的最新素材。这个等待状态仍保留城市卡的顺序和入口；Top Shelf 至少要有一张真实海报才显示。某个封面更新通过核验后通知桌面。扩展逐张重新确认当前授权、Photos 历史、封面可读性、拍摄坐标和时间、修改版本、截图与录屏、隐藏状态，以及实际相册归属。照片库新增素材、修改其他资产时，完整授权下的扩展会读出变更并保留仍合格的卡。某个封面被删除、隐去、改坐标或成员证明不符，只撤该卡，并用公共地图替换包含该点的个性图。权限变化、有限授权的选择变化、被排除相册内容变化、历史过期或不可读时，撤下私人展示，等待正式更新。点击深链时，宿主还会核对历史变更是否涉及该城市照片墙内已有成员；涉及成员时等待增量同步。[旅程发布与固定成员](../PhotoEarth/App/JourneyShelfPublication.swift) · [资格检查](../PhotoEarthTopShelfShared/JourneyShelfPhoto.swift)

主 App 在前台串行准备至多 24 张小海报，优先尝试本机照片，最多为五张缺图项补取 iCloud 预览。扩展优先取已绑定的预备海报与本机小预览，对最近的两张缺图项允许网络。某城市已核实资格但像素暂不可读时，显示深色行李箱占位，保留该城市的到访顺序、标题和固定成员深链。向 Photos 请求有界、适合完整画幅的预览，直接从完整图像居中裁切成 2:3 海报。首先渲染 480 × 720，必要时再降低显示尺寸，输出 JPEG 会移除来源文件的附加元数据。此前 16:9 的缓存图片不会作为竖海报来源。桌面图片交付直接使用内含缩略图的本地 data URL，扩展的私有文件只作缓存。内联海报兼容既有的 56 KiB 预览，地球单图可达 192 KiB；Base64 和系统消息另有开销。Live Photo 和视频只展示静帧。代码为整次图片读取设置四秒预算；这不是 Home Screen 的实测响应时延。Photos 实际传输量由系统决定。关闭、改范围或丢失权限会撤回共享项并通知系统刷新；扩展下次被调用时清理私有临时图。已交给桌面的缓存何时移除由 tvOS 决定，不能承诺用户按下开关的瞬间系统像素同步消失。城市卡没有人为设置的到期日。[系统扩展实现](../PhotoEarthTopShelf/ContentProvider.swift)

深链只接受已发布的规范地址。点击时从快照验证当前路线，并用最新索引重新解析同一城市的访问成员。路线绑定有序访问 ID 与坐标。升级时扩展会拒绝旧的完整旅程快照，等 App 发布城市数据后再显示。

## 无可展示城市时的桌面

主 App 的品牌资源只包含应用图标与商店图标。扩展返回 nil 时，地图首图随整个动态区段收起。[品牌资源检查](../Scripts/verify_tv_home_brand.sh) · [首卡原图与采集](TOP_SHELF_MAPKIT_ART.md)

## 共享 JPEG 文件的签名条件

2026-11-19 只读核对了开发团队的 Bundle ID、真机开发构建的签名及其两份嵌入式描述文件。主包 `com.doupi.PhotoEarth.PhotoEarth` 已显式注册，App Store Connect API 返回 In-App Purchase 和 iCloud 两项能力。精确查询扩展 `com.doupi.PhotoEarth.PhotoEarth.TopShelf` 返回 0 个显式 ID。主包使用专有开发描述文件，扩展使用 tvOS 通配开发描述文件。两份最终签名及两份描述文件均缺少 `com.apple.security.application-groups`，现有的共同钥匙串权限只覆盖钥匙串项。Developer Portal 的网页会话当时未认证，因此团队名下是否已有可分配给本项目的独立 group ID 尚未核实。[签名读回](../.local-test-data/earth-20261119/television/top-shelf-signing-readback.json) · [tvOS 支持的能力](https://developer.apple.com/help/account/reference/supported-capabilities-tvos/)

采用共享文件目录时，团队管理员需为扩展显式注册上述标识，选用同一团队中本项目专属的 App Group，并将它关联到主包和扩展两个标识。可选的新标识为 `group.com.doupi.PhotoEarth.RecentJourneys`。两个 target 的 Debug、Release 签名都要声明同一个 App Groups entitlement，并重新生成对应的开发、分发描述文件。主包有单独的 Debug 和 Release entitlements，需分别核对。本次未更改开发者账号。[注册 App Group](https://developer.apple.com/help/account/identifiers/register-an-app-group/) · [为标识启用能力](https://developer.apple.com/help/account/identifiers/enable-app-capabilities/) · [Xcode 配置 App Groups](https://developer.apple.com/documentation/xcode/configuring-app-groups)

签名生效后，主包和扩展可用 `FileManager.containerURL(forSecurityApplicationGroupIdentifier:)` 取得同一根目录，在其中原子写入少量去除元数据的 JPEG，再发布对应快照。关闭展示或撤回权限时同步清理共享预览。应从两个包的最终签名和描述文件读回相同 group，实际跨进程读取 JPEG，再在物理电视主屏核对照片像素、关闭后的动态区段撤回及重新授权后的更新。Apple 的 Full Screen Top Shelf 示例使用扩展包内的 JPEG；可用公开的随包图片作为阳性对照。系统是否显示共享目录的真实照片须以 PineBoard 画面核实。[Apple Top Shelf 示例](https://developer.apple.com/documentation/tvservices/building-a-full-screen-top-shelf-extension) · [共享容器 API](https://developer.apple.com/documentation/foundation/filemanager/containerurl(forsecurityapplicationgroupidentifier:)) · [TVServices 图片接口](https://developer.apple.com/documentation/tvservices/tvtopshelfitem/setimageurl(_:for:))

## 城市封面取样

首页与系统主屏按同一个达标代表访问取样。最近一次达标访问有其他已达标历史访问时，优先选最多 18 张；较早的访问用剩余名额，空余名额可继续从最近访问补足。一趟有足够分散的照片时可以独立填满 24 张。每个访问先取最新、收藏及最早的可用画面，再从最长的尚未采样时段选接近中点的照片。每个已选时刻两分钟内的图留给其他时段，避免短连拍挤满。每次查询只从照片的时间索引取边界候选，排除隐藏和不可用素材后最多交给 Vision 24 张。

用客厅电视的只读索引重放巴塞罗那的 1,120 项素材，得到 24 张不同候选。巴塞罗那当地 10 月 2 日至 6 日分别抽到 1、7、8、7、1 张，拍摄时间最接近的一对相隔约 54 分钟。用已在本机保存的对应照片预览运行相同的 Vision 风景判定和评分，第 22 张城市俯瞰是唯一通过门槛的候选，拍于当地 10 月 4 日 18:36。横卡以城市为主，竖卡还会保留部分黑色横梁。两张圣家堂外景都进入了候选，但风景置信度均低于 0.45。本次在 Mac 上评分和预览卡面。新版 Apple TV 的实际出图和 iCloud 预览可用性待真机复验。[24 张真实候选](../.local-test-data/earth-20261119/television/barcelona-cover-audit/barcelona-24-candidates.jpg) · [横竖卡对照](../.local-test-data/earth-20261119/television/barcelona-cover-audit/barcelona-cover-comparison.jpg) · [评分明细](../.local-test-data/earth-20261119/television/barcelona-cover-audit/scores.json)

### 地标和竖卡评分

同一批城市候选先判断原图和 Top Shelf 2:3 裁切是否仍有清楚的地标或建筑特征。用 Vision 的显著主体矩形估算裁切保留比例，并对竖图再次评分；评分和出图使用同一个中心裁切几何。能辨认的地标且显著主体保留比例达到 72% 时优先，其他候选可按裁切后的构图、主体和场景质量入选。裁掉近一半主体的候选不作为正式评分结果。城市评分用于首页、Top Shelf 和分类中的城市封面。

巴塞罗那继续使用上面同一批 24 张，Mac 重跑后从第 22 张城市俯瞰换成当地 10 月 4 日 15:57 的第 24 张圣家堂外景。仪器估算保留该照片显著主体框的约 94%，第 12 张横拍圣家堂约保留 57%。这些是对可见主体的估算，用实际竖图可以同时看到尖塔与立面。此处记录本机 Vision 重跑与裁切预览，新的评分尚待实体电视验证。[三张竖卡对照](../.local-test-data/earth-20261119/television/barcelona-cover-audit/landmark-v2/barcelona-landmark-poster-comparison.jpg) · [24 项本机评分](../.local-test-data/earth-20261119/television/barcelona-cover-audit/landmark-v2/scores.json)

### 本机封面判断与真机计时

封面判断请求长边约 512 像素的本机预览，PhotoKit 的网络访问为关闭。只有云端预览或本地请求无结果时，跳过候选，不把缺图持久化为低分。展示阶段优先读取已选静态照片的全尺寸 Photos 当前版本，保留照片编辑效果并按卡片尺寸降采样。Top Shelf 继续使用 2:3 海报和现有缓存大小预算。原图暂不可用时，展示可以使用同一张照片的预览。这一步可以按现有可见范围和网络预算向 iCloud 取图。

客厅第三代 Apple TV 4K 上，使用同一批巴塞罗那真实小图隔离计时。冷跑单批端到端 4.29 秒，其中 Vision 4.19 秒。暖跑端到端 3.60 秒，其中 Vision 3.53 秒。两次都选第 24 张圣家堂，排序均小于 1 毫秒。此前诊断额外试取两张本机未拿到的 PhotoKit 预览，两次都成功，合计取小图约 1.39 秒。实际 App 另一次前台发布从开始刷新计，初始 24 卡约 0.61 秒提交给系统，前五张评分完成 5.44 秒，全排处理完成 14.60 秒。发布时间记录的是 App 处理，不包含系统主屏实际绘制和初次扫描。[第一轮真机计时](../.local-test-data/earth-20261119/television/cover-timing/device-timing-summary.json)

纯本地评分版随后在同一台电视干净安装、重建真实图库索引并复验。隔离的 PhotoKit 评分请求 24 张，实际本机交付 13 张，另 11 张跳过。取图与评分合计 0.83 秒，最多同时进行的网络图片请求为 0。评分为 13 张中的第 9 张，电视的实际巴塞罗那 Top Shelf 卡面展示该建筑照片。用于纯计算对照的全部 24 张本机预览，另两轮端到端实测 1.28 秒和 1.01 秒，均选第 24 张圣家堂。两轮实验跨不同启动和缓存状态，计算耗时存在差异。测试预览在设备上已清理。[纯本地真机计时](../.local-test-data/earth-20261119/television/cover-offline/device-timing-summary.json) · [巴塞罗那实际主屏卡面](../.local-test-data/earth-20261119/television/native-cover-offline-barcelona.png)

## 验收

加入最低素材数之前，城市版本在本机用客厅电视的只读索引副本复算。默认过滤后的 627 次可见访问生成 24 张城市卡。首五张与首页 Dock 的城市及顺序相同，后续 19 张接续首页城市排序，每张都解析到首页对应城市的照片范围。清空或替换索引里的完整旅程集合，不影响城市列表。[本机复算](../.local-test-data/earth-20261119/television/recent-city-probe/result.log)

在「客厅」Apple TV 干净安装城市版后，实际系统横排与 App 首页的前五座城市及当时封面吻合。顺序为杭州、贝尔格莱德、巴塞罗那、格拉纳达、塞维利亚。遥控器从地球向右逐张遍历到第 24 张。系统回执记录 24 张真照片海报、0 张占位，实际交付顺序与新装版本的可见 SQLite 索引逐项相符。第六张巴黎打开 1,327 张照片的墙。末张名古屋打开 234 张照片的墙，宿主收到并打开同一路线。两座城市的真实墙总数与各自索引一致。[首页和主屏对照](../.local-test-data/earth-20261119/television/city-scroll-compare-review.jpg) · [第六张卡](../.local-test-data/earth-20261119/television/native-city-scroll-card-06.png) · [巴黎照片墙](../.local-test-data/earth-20261119/television/native-city-scroll-six-wall.png) · [第 24 张卡](../.local-test-data/earth-20261119/television/native-city-scroll-card-24.png) · [名古屋照片墙](../.local-test-data/earth-20261119/television/native-city-scroll-twenty-four-wall.png) · [实机系统回执比对](../.local-test-data/earth-20261119/television/city-scroll-audit/provider-matches-index.json)

真机 UI 门禁 `RealTVJourneyShelfUITests/testScrollsTheSystemCityShelfAndOpensAnOlderCity` 使用 `PHOTOEARTH_REAL_TV_CITY_SHELF=1`，并传入从电视索引复算的有序城市标题 JSON 与目标位次 `PHOTOEARTH_CITY_SHELF_TITLES`、`PHOTOEARTH_CITY_SHELF_TARGET`。先选中 PhotoEarth 主屏图标或地球卡。门禁逐张保存实屏，打开目标后用辅助功能树核对照片墙标题和照片。Vision 曾把第八张生僻字误读为「淮」。复核原图后，仅在测试输入中允许该识别结果，再单独点开第八张核对真实墙标题和内容。[真机门禁](../PhotoEarthUITests/RealTVJourneyShelfUITests.swift) · [第八张复验](../.local-test-data/earth-20261119/television/city-scroll-rare-glyph.xcresult) · [完整 24 张真机复跑](../.local-test-data/earth-20261119/television/city-scroll-final-24.xcresult) · [统一截图索引](../.local-test-data/earth-20261119/验收截图/index.html)

1. 在本机泛型 tvOS 目标构建，核对主包的 `PlugIns/PhotoEarthTopShelf.appex`、扩展点 `com.apple.tv-top-shelf`、两个包实际签名的钥匙串访问组与对应 Info.plist 值，并对主包执行嵌套签名校验。本轮已验证 Debug 开发签名路径；App Store 分发配置另需匹配分发签名和扩展标识。
2. 在已有照片权限和已生成索引的实体 Apple TV 正常打开 App。运行 `PhotoEarthTests/RealTVJourneyShelfTests/testPublishedCityMatchesTheHomeDockAndVisibleLibrary`，测试 runner 设 `PHOTOEARTH_REAL_TV_SHELF=1`。测试宿主运行正常 AppModel 并建立发布；单独执行真实相册排除门禁时仍用隔离宿主。用例只读比对正式 SQLite 成员，输出仅限私有 xcresult 的不透明 URL。
3. 将该 URL 传入同一台电视 UI runner 的 `PHOTOEARTH_JOURNEY_SHELF_URL`，同时设 `PHOTOEARTH_REAL_TV_SHELF=1`。运行 `PhotoEarthUITests/RealTVJourneyShelfUITests/testSystemJourneyLinkOpensItsPhotoWall`。此步骤验证系统 URL 启动与真实照片墙。
4. 单独在主屏第一排聚焦 App，核对首张宽地球和前五张竖海报能与首页 Dock 对应，再继续向右，确认第六张及更早的城市依次出现。点击首张应直接进入可操控地图；点击一张真实城市海报后核对与首页对应城市的照片范围。关闭 App 内的最近城市主屏展示，回到主屏确认整排动态内容已撤下，再恢复原设置。Debug 扩展在系统真正调用时写入当次时间、原因和成功条数；之后运行第 2 步可在 xcresult 读取聚合回执。若图标未在第一排，需要用户同意变更桌面布局或用户自行移动，不能把应用内显示的卡片计作主屏截图。

用户明确要求保留 PhotoEarth 在第一排时，可单独运行 `PhotoEarthUITests/TVHomeShelfLayoutUITests/testMovePhotoEarthToFirstHomeRow`，在测试 runner 的环境设置 `PHOTOEARTH_MOVE_HOME_ICON=1`。它检查 PineBoard 当前焦点，确认图标后通过实体遥控器长按进入系统编辑菜单；已确认位于第一排时直接结束。若系统隐藏图标或菜单的辅助功能元素，可先在 DeviceHub 看到被选中的 PhotoEarth 名称，在测试环境写入这次目视确认的 Unix 秒数 `PHOTOEARTH_HOME_FOCUS_CONFIRMED_AT`，以及 `PHOTOEARTH_HOME_HOLD_ONLY=1`。该入口的确认有效期为 90 秒，读取选中状态或截图中的图标名称后执行一次长按并留下系统画面和可用的 AX 树，供操作者接手菜单。[实体主屏布局门禁](../PhotoEarthUITests/TVHomeShelfLayoutUITests.swift)

[范围与链接门禁](../PhotoEarthTests/JourneyShelfTests.swift) · [快照和换代门禁](../PhotoEarthTests/JourneyShelfFormatTests.swift) · [真机只读门禁](../PhotoEarthTests/RealTVJourneyShelfTests.swift) · [真机深链界面门禁](../PhotoEarthUITests/RealTVJourneyShelfUITests.swift)

### 不带 XCTest 的真机诊断

Debug 版以 `--qa-shelf-report` 参数正常启动后，宿主在前台每两秒原子更新一次 `Library/Caches/PhotoEarth/ShelfQA/summary.json`，一轮最多三分钟；重新切回前台重新计时。可用 Xcode 的设备容器读取或 `devicectl device copy from` 取出。普通启动和 Release 均不会写它。报告保留系统实际授权、旅程总数、可展示的最近城市数、发布数、钥匙串状态、索引和快照的历史标记校验、可从系统打开的不透明 URL。仅当系统真的调用过本 Debug 扩展时才会有 `provider` 字段，附执行时间、结果和条数；比较当次时间戳可排除旧回执。关闭 App 回到主屏后，再切回之前以诊断参数启动的 App，报告会读出扩展刚写入的结果。`lastReceivedRoute` 为本进程收到的深链摘要，`lastOpenedRoute` 为与当前城市的可见成员成功匹配的摘要。报告不含照片 ID、相册名、坐标和地名。

### 此前完整旅程版本的实体电视验收

下述截图和真机读数来自切换到首页城市口径前的版本。

此前实体电视在干净安装、授予权限并完成首轮扫描后，正式宿主读到 27 趟旅程。最近 5 趟均合格，钥匙串已发布 5 项，索引和发布快照的 Photos 历史均为当前版本。这一读数来自宿主诊断；系统扩展实际展示须另看当次 provider 回执和桌面截图。

首次实屏已确认旅程栏目和卡片标题出现，但以扩展私有临时文件 URL 提供的图片持续显示占位，且每项的到期日被桌面解释成剩余分钟数。已移除逐项到期日。改为内联 JPEG 后，Mac 通过 Foundation、URLSession 和 ImageIO 读取，实体电视的 PineBoard 也已显示真实旅程照片。首张原生 MapKit 地球和竖海报已在新版实体电视桌面复验。已知另一条本地交付路径是注册 App Group 并从其 Caches 提供文件；现有开发配置只共享钥匙串。[系统 URL 接口](https://developer.apple.com/documentation/tvservices/tvtopshelfitem/setimageurl(_:for:)) · [到期日的系统语义](https://developer.apple.com/documentation/tvservices/tvtopshelfitem/expirationdate) · [Kodi 的共享缓存实现](https://github.com/xbmc/xbmc/blob/master/xbmc/platform/darwin/tvos/tvosShared.mm)

公开路由为 `photoearth://globe`。深链不携带坐标，关闭主屏展示会撤下整排动态内容。关闭后的旧旅程 URL 不再放行，已发布且仍有效的旅程沿用原 URL。可运行真机 UI 用例 `RealTVJourneyShelfUITests/testPublicGlobeLinkOpensDirectManipulationAndReturns` 核对首卡进入操控层、唤出缩放工具和逐级返回。[原生区段与尺寸](../PhotoEarthTopShelfShared/JourneyShelfLayout.swift) · [路由门禁](../PhotoEarthTests/JourneyShelfFormatTests.swift)

首次未授权时，从系统 URL 进入的电视截图已经显示空地球。该次 XCTest 在原有前台进程的辅助功能握手阶段超时，遥控器步骤尚未执行。常规 URL 用例现先启动受测进程，等其辅助功能树就绪再发送深链。要验证从系统首卡实际进入的同一进程，请先用遥控器在主屏选中并点开「滚动地球」，再单独运行 `RealTVJourneyShelfUITests/testSelectedSystemGlobeRespondsToRemote`，同时设置 `PHOTOEARTH_REAL_TV_SHELF=1` 和 `PHOTOEARTH_REAL_TV_SHELF_PRESELECTED=1`。这个用例在实体电视上按 Play/Pause 和 Menu，通过系统截图核对地球胶片、缩放工具条和返回后的胶片，保留三张私有 xcresult 附件。画面识别覆盖简体中文与英文。另可直接使用实体遥控器完成同样的三步并保存原生截图。

从诊断报告可读到当前地球图来源、范围是否匹配、像素尺寸、图片字节数、主 App 发布的最近到访日期顺序。系统扩展真正执行后另附其实际交付的到访日期顺序、真实与占位海报数量。真机门禁 `RealTVJourneyShelfTests/testNativeGlobePreviewContainsTheRegionalMapCredit` 使用 `PHOTOEARTH_REAL_TV_SHELF=1`，将实际从当前范围读回的 JPEG 保存在私有 xcresult，校验尺寸、地表像素和该地区的原生地图署名。该文件可能呈现用户去过的地点，留在本机验收目录。


最终干净安装时，实体电视首次未授权的扩展回执为 `nil-noAccess`，桌面只显示系统 tv 背景。完整授权和扫描后，最近五张真实旅程海报与个性 MapKit 地球在第一排第三格恢复。关闭撤下、重新开启、首卡遥控操作与首趟照片墙均已在设备核对。测试程序清理后再次从电视直接截取 4K 屏幕。[最终主屏原图](../.local-test-data/earth-20261119/验收截图/原图/eeb9e553dfb46c60e2a041d6e8838e2c64e10be2bc39ebbbab47adcc77261d8c.png) · [完整证据时间线](JOURNEY_REFACTOR_ACCEPTANCE_2026-11-19.md)


### 11 月 19 日的 Mac 封面实验

首页与 Top Shelf 使用最近一次达标到访，最近到访页逐趟选图。城市照片墙继续涵盖该城市的所有成员到访。沿用 Mac 实验的 Vision 分类、美学评分和居中竖卡评估。先试 512、再试 320 像素的本机预览，以最终返回图像的实际像素决定是否能评分。每个缺图名额最多补两张，依次比较同一次到访里的拍摄时间和 GPS 距离。候补归属按与所有首选的综合距离决定，同距候补优先收藏，再按稳定资产 ID 排序。最多 24 张实际评分，累计取图预算 12 秒；显示选定图片仍可使用 iCloud。旧版评分与系统主屏海报按版本失效。

Mac 实验图册含 523 次到访和 6,791 张成功评分的本机预览。使用同一索引重放 App 的 SQLite 候补查询，6,795 个首选名额的 6,518 个候补及其顺序均与实验一致。加入拍摄密度前，App 的选择器在 Mac 上重新评估这批预览，523 次到访的选中照片、评分数量与是否使用兜底逐趟一致。[实验图册](../.local-test-data/earth-20261119/mac-cover-review/index.html) · [候补重放记录](../.local-test-data/earth-20261119/cover-rollout-gates/database-parity.log) · [评分重放记录](../.local-test-data/earth-20261119/cover-rollout-gates/replay/result.log)

### 11 月 19 日的拍摄密度实验

首页、最近到访与 Top Shelf 的城市封面共用同一规则。每次只取一次到访中的可见素材，包含照片、Live Photo 和视频。索引按时间顺序读取 GPS，在距离场景中心 160 米内累计独立拍摄次数。同一场景距离上次拍摄至少 120 秒，或距离本次拍摄事件已过 15 秒、移动至少 40 米且超过两点定位误差之和，才会多记一次。第六次达到满分。密度计算仅读索引，缺少本机预览的素材仍能贡献拍摄信号。

首选最多 24 张，其中保留前 18 个分散时段，最多 6 个名额用于补入反复拍摄场景中的静态画面。候选仍保持两分钟间隔。计算最终排名时，沿用原先的画面质量和竖裁评估，在相同层级内按场景强度增加 0 至 0.09 分；来自同一场景的照片获得相同加分。

在 Mac 上对同一批 523 次到访做了三组对照，共使用 29,998 项可见素材元数据。仅改变采样有 44 趟更换封面；固定新候选、再加密度分有 39 趟更换；最终与原版相比有 74 趟更换。三组均有 468 趟使用画面评分结果，55 趟使用最近素材兜底。格拉纳达的玩偶退出候选，获选的是冰淇淋店门口的手持冰淇淋。宫殿全景和新封面的场景强度都达到上限，现有竖裁主体与地标评分仍使店面胜出。巴塞罗那的圣家堂照片退出首选，新版选中巴特罗之家外立面。用同一批小图的 Vision 分数重放 App 的 SQLite 和完整选择流程，523 次到访的入评照片、赢家和兜底原因均与密度实验逐趟一致。比较图和文件名保存在本机。[App 选择结果核对](../.local-test-data/earth-20261119/cover-rollout-gates/density-replay/result.log) · [523 趟三组对照](../.local-test-data/earth-20261119/mac-cover-density-review/index.html)

### 11 月 20 日 · 完整画面选封面

首页与 Top Shelf 的城市卡从最近一次达标到访选图，最近到访页从每次到访单独选图。沿用按时段和拍摄密度挑选候选、本机缺图时补位的规则，每次最多评 24 张。Vision 在完整构图的小图上计算地标置信度、风景分类、美学和人脸占比。通过质量门槛的地标优先，同层再综合画面评分、收藏和拍摄密度。选出照片后，首页首排按 5:3、Top Shelf 按 2:3 居中显示。评分期间只用本机预览，卡片展示可按需读取已选照片的高清版本。评分缓存更新为版本 4，系统主屏快照更新为版本 10。

在 Mac 上用 App 的 Vision 分析和选择器重放 523 次真实到访，共评分 6,792 张既有本机预览。逐趟核对实际入评照片、选中照片和兜底标记，523 趟均与已确认的完整画面图册一致。505 趟由评分选出，18 趟采用该次到访最新素材。在旧电视索引副本上验证了升级、忽略旧评分和重新打开后读取新评分。验证范围为 Mac 重放与 tvOS 构建。[完整图册](../.local-test-data/earth-20261119/mac-cover-fullframe/index.html) · [逐趟核对结果](../.local-test-data/earth-20261119/mac-cover-fullframe/app-validation/replay.log) · [缓存升级验证](../.local-test-data/earth-20261119/mac-cover-fullframe/app-validation/cache-upgrade.log)
