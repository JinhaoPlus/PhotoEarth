# Photo Earth 下一轮体验机会调查（2026-09-12）

最值得推进的方向是：让用户迅速找到一段旧记忆，放下遥控器连续观看，下次打开还能接着看。上一轮已经解决范围表达、连续翻页和主要请求预算；下一轮应围绕完整的观看过程组织这些能力。

本轮是调查和建议，没有改动产品源码、现行产品约定或用户图库。依据包括当前代码、上一轮验收记录、Apple 官方交互资料，以及本轮新增的纯 Swift 状态探针和 5 万条合成 SQLite 查询。没有进行用户访谈或新的 Apple TV 真机测量；下文的体验收益属于待验证判断，合成查询耗时不代表电视端提速倍数。

## 建议的先后顺序

| 顺序 | 改进 | 用户能感受到的变化 | 证据与实施边界 |
| --- | --- | --- | --- |
| 先修 | 可执行的失败恢复、重试保留清晰图 | 遇到慢图或失败仍知道怎样继续 | 有具体代码路径；部分状态已由探针确认 |
| 第一轮主功能 | 按年／月定位，并提供当前范围内的收藏照片 | 不再为了寻找旧旅行连续翻几百张 | 时间与收藏数据已存在；需要真正的数据库 seek |
| 第一轮主功能 | 播放当前照片集合 | 一次操作后可以和家人一起看，随时暂停讲述 | 从现有详情扩展；保持范围、顺序和有限图片预算 |
| 第二轮主功能 | 继续上次观看 | 隔天回来不用重新找城市和照片 | 先支持城市／到访／国家；本机保存最小锚点 |
| 第二轮主功能 | 有日期的到访章节与“再去一次” | 同一城市不同年份的经历重新变得可发现 | 先用真实日期片段；不能把现有 journey 直接当成可靠旅行 |
| 配套 | 情境提示、VoiceOver 状态反馈与真机显示成本测量 | 更容易学会操作，等待与切换更明确 | 不增加强制教程，不以队列数量代替流畅度 |
| 独立实验 | HDR／广色域照片保真 | 雪山、落日、夜景可能更接近原照片 | 必须验证 PhotoKit、解码、显示和电视整条链路 |

## 1. 先把失败后的下一步做对

### 原范围失效时，详情的 Reload 可能没有作用

用户在第 48 张等待下一页，若冻结投影失效，宿主清空 `wallRecords` 并将 `wallNextOffset` 设为 `nil`。详情仍可能保留等待续页状态并显示 Reload，而其调用的加载器要求 offset 非空才工作。

证据：[宿主加载与错误处理](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/Globe/GlobeView.swift:584)、[详情恢复按钮](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/PhotoViewer/PhotoDetailView.swift:87)、[浏览状态更新](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Domain/Models/PhotoBrowsingSession.swift:19)。

本轮使用真实 `PhotoBrowsingSession` 源码运行纯 Swift 探针：清空来源并退回当前照片后，等待状态仍为 true；依据当前视图条件会显示 Reload，而宿主 offset 条件不接受加载。它证明状态组合存在，尚未测得真机触发频率。[探针结果](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/.local-test-data/experience-opportunity-research-2026-09-12/terminal-recovery-results.json)

建议把恢复动作建模为“可以重试当前查询”或“原范围已失效，需要返回并重新圈定”。不能静默换成新范围，也不能给用户一个无效按钮。正常 Back 层级保持原样；正在加载、查询失败和真正到达末尾要分别反馈。

### 同一张照片重试时可能从清楚退回模糊

加载器优先选择调用方传入的最初墙预览，再考虑当前已显示的图片。因此“墙预览 → 更清楚的中间图 → 下载失败 → 重试”可以退回旧墙预览。[预览选择](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Services/PhotoLibrary/PhotoLibraryService.swift:191)

建议同资产、同内容修订的重试保留已有最佳可用图，清晰版本到达后再替换；编辑失效后仍以 PhotoKit 的新内容为准。保留类型化的云端等待、超时、资产不存在和权限错误。若 PhotoKit 没有给进度，就不显示百分比；操作层可以安静地显示“正在获取清晰版本”。现有重试 Focus 修复继续保留。

另需补一条条件性资源回归：调度器将超预算的非最终图像回调转为最终失败并移除 job，但没有同步取消底层 token；若 PhotoKit 仍持有该请求，后续工作会脱离此 job 的计时与预算管理。这是分支审查发现，未观测到真机触发。[接收与完成逻辑](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Services/PhotoLibrary/SharedPhotoImageScheduler.swift:238)

验收应覆盖：失效范围与暂时数据库错误采用不同恢复动作；较清楚中间图在失败重试后不倒退；拒绝超预算中间图时原生请求被取消，迟到回调不能继续占用有效会话。

## 2. 用时间和收藏缩短寻找旧记忆的过程

一个城市有几千张照片时，稳定分页解决了加载方式，却仍要求用户长时间向下翻。当前墙头没有年月定位入口；照片已经保存拍摄时间与收藏状态，收藏目前主要显示为心形标记。[墙标题](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/PhotoViewer/ViewportPhotoWall.swift:184)、[照片事实字段](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Domain/Models/TravelModels.swift:12)

建议在墙的固定顶部增加克制的“按时间查找”入口：选年、选月，直接到达该时间附近。顶部同时保留城市／到访范围，不能因为选时间退回全球照片。先支持城市、国家和到访集合，再扩展冻结地表范围。

必须区分两种行为：

- **跳到某月**只改变当前位置，原集合总数保持不变。
- **只看某月**会改变过滤条件，总数、分页和详情都必须使用相同条件。

首版推荐采用“跳到某月”，避免用户在不知情时进入过滤状态。年份／月份摘要按需从 SQLite 查询，不先加载完整资产 ID；无照片月份不可伪造记录。日期分组必须定义时区口径，不能自动把 Apple TV 当前时区显示出的日期称为照片拍摄地当地日期。

在同一范围增加“收藏照片”入口，可以直接使用用户在 Photos 已做出的选择。例如 3,000 张城市照片中有 35 张收藏，电视端便有了一条可解释的短路径。收藏为空时明确说明；不自动挑普通照片冒充收藏，不改写 PhotoKit。若以后做自动精选，也应与“收藏”分开命名。

### 新的 SQL 证据：去掉 OFFSET 后，深页仍可能从同地点的开头过滤

当前单地点查询的混合排序续读条件为 `date < anchor OR (date = anchor AND id > anchorID)`。在本轮合成数据中，查询计划只把地点条件用作索引入口，日期与 ID 仍可能成为后续过滤。[当前 SQL](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Services/Persistence/TravelIndexStore.swift:278)

5 万条同地点记录、从第 4 万条续读 48 张，SQLite 3.51.0、每种查询五次取中位数：

| 数据分布 | 当前 OR 续读 | 显式限定日期的 OR | 同日期／更早日期两个有界分支 |
| --- | ---: | ---: | ---: |
| 每 8 张共享时间 | 约 360,900 VM 指令／1.594 ms | 约 1,000／0.020 ms | 约 2,400／0.035 ms |
| 全部共享时间 | 约 441,200 VM 指令／2.059 ms | 约 441,200／2.114 ms | 约 2,400／0.036 ms |

三条续读路径的 48 个有序 ID 校验一致。两个分支分别限制返回量，再合并为同一日期降序／ID 升序；计划仍有小规模临时排序。正式分页接入还必须保留额外一条的下一页判断，不能直接把此探针替换为产品实现。直接日期跳转是另一种语义，没有拿它与续读结果做相同 ID 声明。

这不推翻上一轮持续计数游标和减少 OFFSET 的收益；它说明年月跳转与深层恢复需要进一步验证实际索引范围。结果仅覆盖单地点、内存 SQLite 与合成数据，不包含多地点合并、RTree、原生投影或设备性能。[结果](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/.local-test-data/experience-opportunity-research-2026-09-12/time-seek-results.json)、[可复跑脚本](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/.local-test-data/experience-opportunity-research-2026-09-12/time_seek_probe.py)

深层读取还应逐步改为有限记录窗口。当前图片请求有预算，但宿主照片数组、ID 集合和详情位置表仍随已浏览数量增长，这不是已证实的内存泄漏。时间跳转与恢复可以只读取锚点附近几页，保留必要的行几何、Focus 与返回锚点，离远的记录页按需再取。冻结地表若引入临时可见结果表，还要单独测量磁盘、WAL 读租约和失效清理，不把它变成新的全库常驻层。[宿主记录追加](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/PhotoViewer/CollectionPhotoWall.swift:130)、[详情位置表](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Domain/Models/PhotoBrowsingSession.swift:8)

验收：同时间照片、首尾月份、跨年、收藏变化与删除不漏不重；深层定位不需要先遍历前面几万张；长时间浏览后记录窗口仍受限，回翻不丢 Focus。界面实验比较“找到某年某月的一次到访”所需时间、按键数量及返回后是否知道自己在哪里。

## 3. 先提供“播放当前集合”，让人能放下遥控器

当前已经可以左右连续翻照片，但每次切换仍需输入。代码没有照片播放状态机或 Play/Pause 处理；偏好中的旧 `autoplayEnabled` 字段不代表播放能力已实现。Apple TV 自带 Photos 提供可控时长的幻灯片与支持暂停、前后切换的回忆播放，说明这种操作符合平台已有习惯，但不能据此断言 Photo Earth 用户一定需要同样的默认行为。[Apple 幻灯片](https://support.apple.com/guide/tv/create-a-slideshow-atvb653f56b0/tvos)、[Apple 回忆播放](https://support.apple.com/guide/tv/watch-photo-memories-atvb4928b087/tvos)

建议第一版只播放用户刚选定的城市／到访／收藏集合：详情操作层提供“播放”，Play/Pause 控制开始与暂停；启动 App 时仍先显示地球。播放沿当前集合和明确顺序进行，不自动跳去别的城市。中键继续展开操作层，Back 仍回原墙并定位最后实际观看的照片。

观看节奏应由图片可用状态驱动：

1. 当前照片以原始比例展示，不默认裁切或持续推拉。
2. 下一张已有真实可用预览后再切换；清晰版可以继续升级。
3. 下一张仍在云端时保留当前照片，允许立即跳过或暂停，不用黑屏占据观看时间。
4. 暂停后允许长时间讲述，用户重新按播放才继续。停留时长提供少量选择，具体默认值通过沙发观看测试决定。

当前邻图只有前后各一张、960 px 本地请求；切换后新的适屏请求不等于已经取得预览。[邻图准备](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Services/PhotoLibrary/MemoryThumbnailStore.swift:66)。应优先完成“把在途预览交接给当前照片”，继续共用预算。增加云端邻图预取属于对现行本地预取规则的调整，需单独测量再决定。

播放时才按需管理系统空闲计时器，离开播放场景恢复，不能全应用永久阻止休眠。[Apple 空闲计时器说明](https://developer.apple.com/documentation/uikit/uiapplication/isidletimerdisabled)。配乐和正式旅行电影可以后置；当前集合的安静播放不依赖完整旅程推断、音乐订阅或导出视频。

验收：50 张包含本地／云端／不可用照片的集合能播放、暂停、前后切换、跨页和退出；操作不被下载阻塞；计时从实际可观看画面开始；不重复占用网络任务，不显示旧照片的新日期。真实照片准备时延要与序号切换时延分开报告。

## 4. 把“返回同一张”延伸为“下次接着看”

当前集合、照片和分页位置主要保存在视图 `@State`；重新开墙会重置列表。持久偏好只有上次地点 ID，没有照片观看锚点。[会话状态](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/Globe/GlobeView.swift:20)、[重新开墙](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/Globe/GlobeView.swift:558)、[偏好字段](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Services/Persistence/PreferenceStore.swift:3)

建议首页提供可选“继续观看 · 东京 · 2019”。先支持城市、到访和国家：本机保存少量范围描述、最后照片 ID、日期和过滤条件，重新打开时校验照片与范围，再按锚点读取附近页。用户仍可直接把玩地球；不自动打开私人照片详情。

不要保存旧 offset 作为唯一恢复依据。新照片、删除和重聚类都会使位置变化；地点 ID 本身也不是跨任意图库编辑不变的永久城市身份。照片 ID、坐标和完整集合不得进入 KVS。

冻结投影闭包与 WAL reader 不能跨进程保存。地球范围入口可以先恢复“上次观看的区域”，重新圈定后产生新集合，并明确这是重建视野；不能宣称恢复了上次一模一样的严格投影照片集合。

验收：看到第 600 张后终止进程、重新进入，一次选择继续；最后照片删除、收藏取消、索引重建、权限撤销、缓存丢失和语言变化均有合理降级。回翻读取附近记录，避免为了恢复第 600 张加载前 599 张大图。

## 5. 用真实日期组织章节，让旧经历重新出现

当前首页城市入口聚合同城访问，“最近到访”每项则通常只有一个地点片段；两种墙可能都只显示城市名和数量。[两种集合](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Domain/Models/PlaceCollection.swift:59)

先把它们说清楚：“东京 · 这次到访 · 9 月 3–8 日”和“东京 · 全部到访”，提供显式切换。再在首页后续货架加入有限的“再去一次”：从已有真实日期片段中选择较久未看的几项，显示城市与年份。用户浏览时固定卡片身份和排序，地名补全只更新文字；仍沿用初始 15、追加 10 的准备预算。

现有 `TravelPlace` 是按时间连续性与距离形成的片段，默认 30 km／72 小时；`TravelJourney` 只根据相邻片段不超过 5 天拼接。[聚类规则](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Domain/Clustering/TravelClusterer.swift:3)、[流式旅程组合](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Domain/Clustering/StreamingTravelClusterer.swift:72)。在规则上，家中持续拍照可以形成很长片段，附近的出游与返回也可能被接入同一 journey。因此直接把这些数据命名成“某年某趟旅行”会放大推断误差。

章节第一阶段只说照片能证明的事实：城市、日期区间和数量。不能根据时间地点猜测“蜜月”“毕业旅行”，不能静默隐藏常驻地。正式旅行电影需要另行建立更稳健的行程边界与身份策略；主地球仍不绘制路线。

验收：同城不同年份、同名不同国家、长时间常驻、短途往返、匿名地点和新增旧照片；章节不能重叠误报，集合数量与实际分页一致。观察用户是否能自然区分“这次去东京”和“东京所有回忆”。

## 6. 两项配套：教会关键操作，确认真实画面收益

探索提示目前进入后约 7 秒淡出，用户是否已经成功长按缩放并不影响它；设置只有提示开关。[提示时机](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/Globe/GlobeView.swift:356)。建议按成功行为逐步减少提示，在首次需要时只教一个动作，设置内保留重新学习入口。不要增加强制多页教程，也不修改已经确认的短按／长按语义。[Apple 情境式引导](https://developer.apple.com/design/human-interface-guidelines/onboarding)

详情已提供辅助功能标签，并在 VoiceOver 开启时显示操作层；实际朗读与遍历仍需真机验证。Next 按钮标签固定，当前照片日期和序号在另一元素上。可在切换成功后合并播报真实日期、地点、序号和收藏状态；快速连续操作只播最终照片，不因图片清晰度升级重复播报。等待、失败和首尾边界也需要可感知反馈，不能编造照片内容。[详情辅助信息](/Users/doupi/WorkYard/idea_sparks/photo_earth/PhotoEarth/PhotoEarth/Features/PhotoViewer/PhotoDetailView.swift:58)、[Apple 播报 API](https://developer.apple.com/documentation/accessibility/accessibilitynotification/announcement)

图片保真度值得独立实验。先用公开 SDR、Display P3、HDR 与 Gain Map 样片验证当前 PhotoKit 返回、解码和电视输出；不要把没有显式 HDR modifier 直接判为当前已经丢失 HDR，也不要把 PNG 截图当 HDR 验收。本机 SDK 与最新在线 PhotoKit HDR 接口存在可用性差异，实现必须以项目实际 SDK 和设备结果为准。[Apple HDR 图像指南](https://developer.apple.com/documentation/UIKit/supporting-hdr-images-in-your-app)

共享调度器的 240 MiB 账本不是 App 内存上限。增加播放前，应测真实 UIImage／IOSurface／地图驻留、图片首帧及显示提交。先用 Animation Hitches 查明停顿，再决定是否在预算内增加后台显示准备；不直接堆更多并发。[Apple 图像显示准备](https://developer.apple.com/documentation/uikit/uiimage/preparingfordisplay%28%29)

## 下一轮如何验收“明显改善”

建议用相同的公开／自愿测试照片，在 Apple TV 4K 真机、实际电视观看距离下比较以下任务，而不是仅统计新增按钮数：

| 任务 | 记录什么 |
| --- | --- |
| 找到某年某月的一次旧到访 | 完成时间、遥控器按键数、找错集合的次数 |
| 选择一个城市，与家人连续看 10 分钟 | 手动干预次数、空白等待、暂停后是否能自然继续 |
| 看至深页，退出并第二天继续 | 恢复步骤、锚点正确性、删除后的降级是否清楚 |
| 弱网跨过第 48/49 张，立即反向并重试 | 首张可用图／清晰图延迟、过期回调、恢复动作是否有效 |
| VoiceOver 连续看照片并回到墙 | 焦点稳定、最终照片播报、等待与末尾是否可理解 |

性能同时记录 P95 输入响应、最长主线程占用、动画停顿时间、连续观看后的内存高水位与返回稳定值。数值目标应在取得真机基线后确定；可先把缓存命中首图 100 ms 内作为待检验目标，不能写成已达成的保证。

本轮最推荐先做：**恢复正确性 → 时间／收藏入口与稳定 seek → 当前集合播放及预览交接 → 本机继续观看 → 日期章节与重访入口**。HDR 和正式旅行电影保持独立验证，避免它们阻挡前面直接改善日常使用的功能。
