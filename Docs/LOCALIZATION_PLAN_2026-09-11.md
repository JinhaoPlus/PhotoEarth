# Photo Earth 多语言与离线地名本地化方案

日期：2026-09-11  
状态：工程实现与遥控器术语审查完成；发布前母语审校与真机长文案验收待完成

## 1. 目标与原则

Photo Earth 面向欧美、日本市场时，需要同时本地化界面文案、日期与数量格式、权限说明、辅助功能文本，以及在线和离线取得的城市／国家名称。多语言改造不能只把 SwiftUI 中的中文字符串搬入翻译文件，也不能让某一种语言的地名继续作为地点、国家或城市的稳定身份。

本方案遵守以下原则：

- 使用 Apple 当前推荐的 String Catalog 和系统 Locale，不自建运行时语言切换框架。
- 应用跟随 Apple TV 的系统／App Language 设置；不在应用内提供语言选择器，也不保存一份独立的语言偏好。
- 英语作为开发源语言，现有中文成为 `zh-Hans` 翻译，不让工程声明的英语开发语言与实际中文源文案继续错位。
- 聚类、照片索引、地点 ID、国家／城市集合身份均与显示语言解耦。
- UI 文案和地理名称采用不同的数据通路；7,342 条离线城市名不进入 `Localizable.xcstrings`。
- 切换语言不得重新扫描 PhotoKit、重新聚类照片或丢弃照片空间索引。
- 翻译保持 Photo Earth 克制、电影感和私人记忆叙事，不按字面机械翻译“记忆”“旅程”“点亮世界”等核心表达。

系统为唯一语言来源：SwiftUI 与 String Catalog 使用 tvOS 为当前 App 解析出的首选受支持语言；用户如果在 Apple TV 设置中单独指定 Photo Earth 的 App Language，也仍由系统统一管理。应用不显示首次语言选择、不增加语言设置项，也不把语言写入 `UserDefaults` 或 iCloud KVS。系统优先采用用户首选语言列表中 Photo Earth 支持的第一种语言；没有匹配时回退到英语开发语言。日期、时间、数字、单位、MapKit 和离线地名都必须使用这一个已解析 App Locale，不能各自读取或保存另一套语言状态。

### 1.1 调试语言与正式体验边界

- 在 Xcode 连接 tvOS Simulator 或开发用 Apple TV 时，开发者可以通过 `Product > Scheme > Edit Scheme > Run > Options` 的 **App Language** 和 **App Region** 临时指定本次启动的语言与地区，用于人工检查 UI、权限说明、日期格式、MapKit 和离线地名。该选择属于 Xcode 的调试启动配置，不是 Photo Earth 的用户偏好，也不写入应用数据。
- UI 自动化测试可以只在 `PhotoEarthUITests` 测试进程中向 `XCUIApplication.launchArguments` 注入 Apple 的 `-AppleLanguages` / `-AppleLocale` 参数。语言辅助代码必须留在 UI Test target，不能移入正式 App target。
- 不在 Debug App 内再实现一套隐藏语言选择器或持久化覆盖，避免调试路径与 Apple 实际语言解析产生差异。切换调试语言后重新启动 App 进行验证。
- App Store 的 Release App 不包含语言选择界面、调试语言字段或自有覆盖逻辑。普通用户只能通过 Apple TV 的系统语言或系统提供的 Photo Earth App Language 配置改变语言；未匹配语言继续回退到英语。

Apple 官方依据：

- [Localizing and varying text with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
- [Using generated localizable symbols in your code](https://developer.apple.com/documentation/xcode/using-generated-localizable-symbols-in-your-code)
- [Preparing your app's text for translation](https://developer.apple.com/documentation/xcode/preparing-your-apps-text-for-translation)
- [Preparing dates, currencies, and numbers for translation](https://developer.apple.com/documentation/xcode/preparing-dates-numbers-with-formatters)
- [Requesting access to protected resources](https://developer.apple.com/documentation/uikit/requesting-access-to-protected-resources)

## 2. 建议语言范围

首批发布语言：

- English：开发源语言，采用适合美国及全球市场的中性英文。
- Japanese：`ja`。
- German：`de`。
- French：`fr`。
- Spanish：`es`。
- Italian：`it`。
- Simplified Chinese：`zh-Hans`，保留当前中文体验。
- Traditional Chinese：`zh-Hant`。

第二批根据 App Store 地区数据和用户量决定：

- Portuguese (Brazil)：`pt-BR`。

日期、时间、数字、小数分隔符和单位继续服从用户的地区设置。除非文案确实存在拼写或语义差异，不为了日期格式单独复制英语地区翻译。

## 3. 现状审查

### 3.1 工程配置

- `developmentRegion` 已经是 `en`，但 `knownRegions` 目前只有 `en` 与 `Base`。
- App target 已启用 `SWIFT_EMIT_LOC_STRINGS = YES`。
- App target 已启用 `STRING_CATALOG_GENERATE_SYMBOLS = YES`。
- 工程偏好 String Catalog，但目前不存在 `.xcstrings` 文件。
- 照片库和位置权限说明直接写在 build settings 中，且只有中文。

因此工程无需引入第三方本地化框架，主要工作是创建 Catalog、让不可自动提取的文案改用本地化类型，并补齐语言资源。

### 3.2 文案与格式

当前正式源码约 27 个文件、237 行包含中文文本，主要分布在：

- 首次授权和照片库准备页面。
- 首页、地球操作提示与缩放工具条。
- 最近到访、国家与城市、照片墙和照片详情。
- 设置、错误和辅助功能标签。
- 聚类与持久化模块生成的占位地点、旅程标题和错误文本。

SwiftUI 直接接收的字符串字面量可以被编译器发现，但以下路径不能依赖自动提取：

- 模型或计算属性返回的普通 `String`。
- 通过三元表达式动态选择的普通字符串。
- 持久化到 SQLite 或 Codable 状态里的显示文案。
- `LocalizedError` 中未经本地化 API 包装的错误描述。
- 由多个字符串片段拼接出的计数和状态句子。

当前还存在明确的中文 Locale 锁定：

- `TravelPlace.dateRangeText` 使用 `zh_CN` 与中文日期模板。
- `PlaceLibraryView` 的日期格式显式指定 `zh_CN`。
- 相机距离直接拼接“米”。
- 多处照片、地点、城市数量直接拼接“张／个”，无法支持英语复数。

### 3.3 地名与身份耦合

当前地名通路有以下风险：

- MapKit 反向地理编码的 `preferredLocale` 固定为 `zh_CN`。
- `BundledWorldPlaceCatalog` 固定用 `zh_CN` 生成国家名。
- 离线 TSV 只保存 `NAME_ZH` 城市名和英语国家 fallback。
- `places` 表只保存一份 `name` / `country`。
- `place_label_cache` 以坐标 basis 为单主键，只能保存一种语言。
- `PlaceLabelBasis.version` 中写死 `zh_CN`。
- `PlaceDisplayLabel.hasCity` 通过“地点”“未知地点”“地名待完善”等中文文案判断是否完整。
- 国家和城市集合使用本地化名称构造集合 ID 或语义范围。
- 示例旅程和 Simulator 十城 fallback 都硬编码为中文。

这些问题会导致切换语言后继续显示中文、不同语言互相覆盖缓存，或因为翻译变化而改变分类身份。

## 4. String Catalog 设计

### 4.1 Catalog 划分

新增：

- `PhotoEarth/Localizable.xcstrings`：应用 UI、错误、状态、辅助功能和示例叙事文案。
- `PhotoEarth/InfoPlist.xcstrings`：`NSPhotoLibraryUsageDescription` 与 `NSLocationWhenInUseUsageDescription`。

当前规模下不需要按 Feature 拆分多个 UI Catalog。以后单一 Catalog 明显影响维护时，再按 `Onboarding`、`Globe`、`Library` 等 table 拆分。

### 4.2 Key 与代码使用

- Catalog 使用稳定语义 key，例如 `settings.privacy.title`、`globe.controls.zoom_in`。
- 英语翻译是 source value，中文不再作为 key。
- 使用 Xcode 已启用的 generated localizable symbols，获得 `LocalizedStringResource` 静态属性或带参数函数。
- SwiftUI View 中静态标题、说明和按钮优先接收 `LocalizedStringResource`。
- 只有地名、PhotoKit 内容等真正运行时数据继续使用普通 `String`。
- 必须给含有“中键”“触摸面”“记忆地平线”等产品术语的 key 添加 translator comment。
- 不拼接可翻译片段；完整句子作为一个 key，让译者能够调整参数顺序。

### 4.3 结构化状态

以下数据不得持久化为已翻译字符串：

- 照片库准备阶段标题和说明。
- 扫描进度、暂停、重试和失败状态。
- 匿名地点占位文案。
- 自动生成的旅程标题。
- 可恢复错误的用户提示。

模型保存枚举、数量、日期、错误码和稳定 ID；View 或 presentation 层根据当前 Locale 转换为 `LocalizedStringResource` / `String(localized:)`。

`TravelPlace.name` 不再承担“真实城市名”和“地点 01 占位符”两种语义。建议让未解析城市为空，并以结构化 label state 表达 loading、resolved、stable unavailable 和 transient unavailable。`PlaceDisplayLabel.hasCity` 只检查数据是否存在，不检查任何语言的 UI 文案。

## 5. 数字、日期、单位和大小写

- 照片数、城市数、地点数、剩余数使用 String Catalog plural variations。
- 所有数字参数保留数字类型交给 Catalog 和 FormatStyle，不在拼句前先手工格式化成语言相关字符串。
- 单个日期使用 `Date.FormatStyle`。
- 旅行起止日期使用 `Date.IntervalFormatStyle`，不维护 `yyyy年M月d日` 模板。
- 相机距离使用 `Measurement<UnitLength>` 与 Measurement FormatStyle，不写死“米”。
- 经纬度保留固定小数精度，但使用 Locale 感知的数值格式；辅助功能描述使用完整本地化句子。
- 不对地名直接调用无 Locale 语义的强制大写。需要视觉大写时优先由 SwiftUI 文本样式处理，并检查日语等没有大小写概念的语言。
- 返回图标使用方向语义符号，例如 `chevron.backward`，不把 `left` 当成返回含义，为未来 RTL 验证保留正确镜像能力。

## 6. 离线城市数据多语言方案

### 6.1 数据源与覆盖

继续使用 [Natural Earth 1:10m Populated Places 5.1.2](https://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-populated-places/)，维持 public domain 归档与 `ASSET_CREDITS.md` 说明。

2026-09-11 对官方 5.1.2 DBF 的只读检查结果：

- 7,342 条 populated-place 记录。
- `NAME_EN`、`NAME_DE`、`NAME_ES`、`NAME_FR`、`NAME_IT`、`NAME_PT`、`NAME_JA`、`NAME_ZH`、`NAME_ZHT` 均为 7,342 个非空值。
- 非空不代表翻译质量已经通过产品审核；发布前仍需抽查重点国家和重点城市。

### 6.2 资源格式

不把城市名放进 String Catalog，也不为每种语言复制完整坐标文件。生成一个版本化的共享多语言资源，建议字段：

```text
NE_ID
latitude
longitude
ISO_A2
ADM0NAME
NAMEASCII
NAME_EN
NAME_DE
NAME_ES
NAME_FR
NAME_IT
NAME_PT
NAME_JA
NAME_ZH
NAME_ZHT
```

按当前数据估算，以上字段生成的 UTF-8 TSV 约 1.05 MB，gzip 约 357 KB。Apple TV 可以接受这一体积，且避免重复坐标与身份字段。首版继续使用可审计的 TSV；只有真实性能数据证明需要时才改为预生成 SQLite 或二进制格式。

生成脚本必须：

- 固定 Natural Earth 输入版本和输出 schema 版本。
- 输出稳定 `NE_ID`。
- 对制表符、换行和异常 ISO code 做确定性清理。
- 按稳定字段排序，保证同一输入生成相同文件。
- 校验总行数、目标语言非空率、重复 ID、合法坐标和 UTF-8。
- 将语言字段和 fallback 选择规则写入脚本测试，不依赖手工修改生成文件。

### 6.3 运行时选择与 fallback

引入一个可注入、可测试的 `PlaceLocale` / localization context。Locale 来源是当前 App Locale，而不是硬编码设备地区或 `zh_CN`。

城市名 fallback 顺序：

1. 与当前支持语言和 script 精确匹配的 Natural Earth 字段。
2. 同语言的基础字段。
3. `NAME_EN`。
4. `NAMEASCII`。
5. `NAME`。

明确映射：

- `zh-Hans` → `NAME_ZH`
- `zh-Hant` → `NAME_ZHT`
- `ja` → `NAME_JA`
- `de` / `fr` / `es` / `it` / `pt` / `en` → 对应 `NAME_*`

国家名优先只保存 ISO 3166 区域码，并通过目标 Locale 的 `localizedString(forRegionCode:)` 生成显示文本。只有 ISO 缺失或系统无法提供名称时，才使用版本化的 `ADM0NAME` fallback。

MapKit 仍为第一来源：

- `MKReverseGeocodingRequest.preferredLocale` 使用当前 App Locale。
- 从 `MKAddressRepresentations.region` 保存区域码，而不只保存已经翻译的 `regionName`。
- MapKit 返回部分字段时，离线补全必须使用同一 Locale，不能混合中文城市与英文国家。
- 仅在 MapKit 明确找不到 placemark 或字段不完整时使用离线目录。
- 保留 45 km 最大匹配距离、球面距离校验、稳定无结果和有限退避策略。
- 不因为多语言扩大离线猜测距离，也不以最近城市无上限补齐。

### 6.4 示例与测试目录

- `SampleTravelIndex` 使用稳定 sample place ID 和离线目录身份，不硬编码中文城市／国家。
- Simulator 十城 fallback 使用同一批稳定地点 ID 和目标 Locale，不维护一套中文数组。
- 构图比例等纯测试标签如果对 UI 可见，也需要通过测试专用本地化资源或中性、稳定 accessibility identifier 表达。

## 7. SQLite 与缓存迁移

### 7.1 目标结构

地点事实与本地化标签分离。建议新的 label cache 至少包含：

```text
basis              精确坐标及解析策略身份
locale             规范化语言／script 标识
city               该 Locale 的城市显示名
region_code         ISO 区域码
source              mapkit / offline
source_version      MapKit 策略或 Natural Earth 目录版本
offline_place_id    可选 Natural Earth NE_ID
attempts
retry_at
updated_at
complete
terminal
PRIMARY KEY (basis, locale)
```

`PlaceLabelBasis` 只表达坐标和算法版本；Locale 不再被写死进一个全局 version 字符串，而是独立列。离线来源的条目和 terminal miss 带目录版本，目录升级时仅失效相关记录。

### 7.2 读取行为

- 启动读取地点摘要时，只 join 当前 Place Locale 的标签。
- 当前 Locale 没有缓存时，先快速尝试离线目录，再按现有预算进入 MapKit 队列。
- 完整的其他语言缓存不占当前语言的新地点准备预算。
- 语言变化只刷新 label presentation、国家／城市集合和受影响的 UI；照片行、RTree、封面和地点坐标不变。
- Resolver 的内存 cache、stable result 和 in-flight key 均包含 Locale，防止跨语言回写。

### 7.3 schema v4 迁移

多语言升级不应让 5 万张图库重新扫描。建议提供原地 schema v4 迁移：

1. 在事务中创建新的多 Locale label cache。
2. 将现有完整城市／国家记录复制为 `zh-Hans` 标签；旧中文占位符不作为成功标签迁移。
3. 保留 `photos`、`photo_locations`、`places`、`journeys` 和全部空间索引。
4. 为地点摘要建立当前 Locale 的 label join；旧 `places.name/country` 暂时只用于迁移兼容，不再作为跨语言事实来源。
5. 迁移成功后更新 schema metadata；迁移失败才按现有可重建缓存策略处理。

这次迁移只处理数百至数千个地点标签，不重新读取或写入所有照片二进制，也不影响 Photos/iCloud 内容。

## 8. 国家、城市集合与稳定身份

- 国家集合按 `regionCode` 分组和生成 ID，不按本地化国家名分组。
- 城市集合的查询范围保存明确的 place ID 集合，不通过当前语言的城市文本重新匹配 SQLite。
- 离线命中时可使用 Natural Earth `NE_ID` 作为城市身份辅助。
- MapKit-only 地点可以按当前解析结果构造显示分组，但集合稳定 ID 应由排序后的成员 place ID 生成。
- 同一国家内同名城市的合并规则继续保留；切换语言后重新构建 presentation collection，但不改变地点成员或照片归属。
- “地名待完善”永远是本地化 UI 状态，不是国家名、城市名或集合身份。

## 9. UI 与辅助功能改造

- 首次授权、扫描、首页、地球、照片墙、详情、分类和设置全部使用 Catalog 资源。
- 遥控器操作说明添加明确的 tvOS 语境注释，避免把“中键”翻译成键盘按键。
- accessibility label、hint、value 与屏幕文案使用同一语言，但可以采用更完整、适合朗读的独立 key。
- 固定 70 × 70 pt Dock 和卡片整体结构不因本地化变化；城市／国家文字允许正确截断，但主要操作和状态句不得被截断。
- 德语、法语等长文案需要重新审视设置双栏、缩放工具条和首页安全区。
- 日语检查禁则处理、自然换行与字重，不通过缩小到不可读字号解决布局。
- 用户可见字符串不得使用 `Text(verbatim:)`；仅诊断指标和固定品牌名可以明确使用 verbatim。

## 10. 测试与验收

### 10.1 自动化测试

- Catalog 完整性：发布语言没有空翻译和未审核关键 key。
- plural：0、1、2 和大数量下的 photo/place/city 文案。
- FormatStyle：不同 Locale 的日期区间、数字、时间和距离。
- 离线目录：东京、巴黎、纽约、雷克雅未克等代表点在所有目标语言的结果。
- script：`zh-Hans` 与 `zh-Hant` 返回不同字段且不会互相复用缓存。
- fallback：缺失精确字段、缺失 ISO、未知语言、目录不可用和超过 45 km。
- MapKit：请求收到正确 Locale，在线部分结果与离线结果保持同一语言。
- 缓存：同一坐标可并存多语言结果；切换语言不会返回旧语言结果。
- schema v3 → v4：保留照片、RTree、地点和旅程，只迁移有效中文标签。
- 分类：不同语言下国家和城市的显示名变化，但成员 place ID 与照片范围不变。

### 10.2 UI 测试

现有 UI 测试不再通过中文按钮名或 `country:冰岛` 一类 identifier 寻址。改用稳定标识，例如：

- `tab-home`
- `tab-countries`
- `library-country-IS`
- `library-city-<stable-id>`
- `photo-detail-capture-date`

建立至少以下运行矩阵：

- 英语全流程。
- 日语全流程。
- 德语或法语长文案流程。
- 简体中文回归流程。
- Double-Length、Bounded String 和 RTL pseudolanguage 布局检查。

伪语言不代表首批发布 RTL 语言，但用于发现硬编码左右方向、不可伸缩文本和截断问题。参考 [Preparing your interface for localization](https://developer.apple.com/documentation/xcode/preparing-your-interface-for-localization)。

人工在电视画面验收时使用 Xcode Scheme 的 App Language / App Region；自动化流程使用 UI Test target 内的 `useTestLanguage(_:locale:)`。二者都属于单次调试启动覆盖，不向正式应用增加运行时语言状态。权限说明也必须通过 Xcode 的 Apple 语言启动配置验证，不能只替换 SwiftUI 环境 Locale。

### 10.3 完成标准

- 所有目标语言可由 Apple TV 系统设置正确选择。
- 权限弹窗、错误、状态、按钮和辅助功能文本全部本地化。
- 正式代码中不存在写死 `zh_CN` 的用户显示和地理编码路径。
- 正式模型不通过中文字符串判断业务状态。
- 所有数量句支持目标语言的复数规则。
- 日期、数字与单位服从用户地区设置。
- 在线和离线城市名使用当前 App Locale。
- 多语言地名缓存互不污染。
- 语言切换不触发 PhotoKit 重扫或照片重新聚类。
- Release 构建、完整单元测试和目标语言 UI 流程通过。
- 在真实 Apple TV 尺寸上复核英语、日语和最长欧洲语言页面，确认 Focus、可读性和电影感没有退化。

## 11. 建议实施顺序

### 阶段一：国际化基础

- 创建 `Localizable.xcstrings` 与 `InfoPlist.xcstrings`。
- 建立语义 key、generated symbols 和 translator comments。
- 将普通 UI `String` 路径改为 `LocalizedStringResource`。
- 把业务状态与中文占位文案解耦。

### 阶段二：格式与测试身份

- 改用 plural variants、Date/Interval/Measurement FormatStyle。
- 本地化错误与辅助功能内容。
- 将 UI 测试改为稳定 identifier。

### 阶段三：多语言地名与迁移

- 升级 Natural Earth 生成脚本和共享多语言目录。
- Locale 化 MapKit 与离线解析器。
- 增加 region code、source 和 source version。
- 完成 schema v4 原地迁移及多 Locale cache。
- 改造国家／城市集合身份。

### 阶段四：翻译与验收

- 先完成英语 source copy 和 `zh-Hans` 回归。
- 完成日语、德语、法语、西语和意大利语翻译。
- 为每种语言建立独立审校分支，让母语译者直接修改两个 `.xcstrings` Catalog，并通过 commit/PR 交付；同时附带电视截图和术语表。无法访问仓库时才使用 `.xcloc` 备用流程。
- 执行目标语言、伪语言、Release 构建和真实 Apple TV 视觉验收。

各阶段应分别提交和验证。不得在 UI 已翻译但地名、缓存仍固定中文的状态下宣布多语言功能完成。

## 12. 2026-09-11 实际落地

### 12.1 系统语言与 UI

- 已新增 `AppLocalization`，显示语言来源为 `Bundle.main.preferredLocalizations`，日期、数字与单位同时保留 `Locale.autoupdatingCurrent` 的地区规则。这会服从 Apple TV 的语言优先级以及系统为 Photo Earth 单独设置的 App Language；应用内没有语言选择器，也没有新增 `UserDefaults` / iCloud KVS 语言字段。系统没有匹配语言时由英语开发语言兜底。
- 已加入英语、日语、德语、法语、西语、意大利语、简体中文和繁体中文共 8 套 `Localizable.xcstrings` / `InfoPlist.xcstrings` 资源。当前 UI Catalog 有 216 个语义 key；照片、地点和记忆数量使用 String Catalog plural variation，日期、时间、距离和经纬度格式改为 Locale 感知路径。
- 首次授权、照片库准备、首页、探索地球、缩放工具、记忆照片带、最近到访、国家与城市、照片墙、详情、设置、错误和辅助功能文本均已移出生产 Swift 的中文显示字面量。剩余中文只存在于兼容旧 v3 占位符的迁移判断，以及明确的简体中文地名测试数据中。
- 权限用途说明的基础值改为英语，并由 `InfoPlist.xcstrings` 提供全部 8 种语言。Release App 包已确认每种语言同时包含 `Localizable.strings`、plural `Localizable.stringsdict` 和 `InfoPlist.strings`。
- 既有简体中文 UI 流程在测试启动时显式使用 Apple 的 `-AppleLanguages` / `-AppleLocale` 参数，不改变产品运行时行为；国家入口已改用 region code，城市集合标识已改用稳定成员地点 ID。新增英语、日语和繁体中文系统语言切换冒烟流程。
- 人工调试统一使用 Xcode Scheme 的 App Language / App Region，自动化语言覆盖继续只存在于 `PhotoEarthUITests`。正式 App target 没有隐藏语言选择器、启动参数解析或语言偏好持久化，Release 用户只能跟随 Apple TV 的系统／App Language 配置。

首批非英语文案已经进入 Catalog，并对首页、导航、返回、地球操作和旧中文回归所需的核心术语做了人工修订。繁体中文首版 UI 文案从简体中文基线按台湾常用词汇与繁体字转换后接入；它不影响城市名，城市名始终直接使用 Natural Earth `NAME_ZHT`。所有首版译文在对应商店发布前都必须由母语译者在独立语言分支中直接审校 `Localizable.xcstrings` 和 `InfoPlist.xcstrings`，以 commit/PR 交付；`.xcloc` Export/Import 只作为无法直接访问仓库时的备用方式。工程不包含运行时翻译，也不会把 UI 文案或用户数据发送给翻译服务。

### 12.2 在线与离线地名

- Natural Earth 5.1.2 目录已重新生成为单个 15 列共享 TSV：稳定 `NE_ID`、坐标、ISO 区域码、国家 fallback、ASCII 名，以及英／德／西／法／意／葡／日／简中／繁中城市名。运行时首批使用其中 8 种目标语言；仅葡语字段预留给第二批，不复制坐标文件。
- 实际资源包含 7,342 个地点，文件为 1,117,137 bytes，SHA-256 为 `60ae962e5b08a6d541c981a2f5cd9ff6c9bb9ec79966ac7eec21327a333fb870`。生成脚本固定期望记录数，并校验输入字段、稳定 ID 唯一性、坐标和 ISO code；App 包中的资源 hash 已与源码一致。
- MapKit 请求的 `preferredLocale`、离线城市字段选择和国家名 `localizedString(forRegionCode:)` 使用同一个已解析 App Locale。离线返回保留 Natural Earth ID、region code、来源和目录版本；45 km 最大距离与球面距离校验未放宽。
- Simulator 十城示例也改为多语言稳定条目。真实用户仍优先查询 MapKit，只有明确无 placemark 或字段不完整时才保守使用离线目录。

### 12.3 身份与缓存迁移

- `TravelIndex` schema 已升到 v4。`place_label_cache` 采用 `(basis, locale)` 复合主键，可让同一坐标的英语、日语等标签和 retry/terminal 状态并存；读取只叠加当前语言，旧语言不会从 `places.name/country` 泄漏回来。
- v3 数据库在首次打开时原地迁移：旧标签只作为 `zh-Hans` 导入，照片表、RTree、地点、旅程、同步令牌和扫描进度保留，metadata 从 3 更新到 4，不触发 PhotoKit 重扫或重新聚类。目录／来源元数据也随新标签写入缓存。
- 国家集合优先按 ISO region code 分组；城市集合范围保存稳定的地点 ID 集合，不以翻译后的名称作为照片查询身份。聚类生成的未解析地点名和旅程标题不再写入中文占位字符串。

### 12.4 本轮验证

- Debug tvOS Simulator 构建通过。
- Release tvOS Simulator 无签名构建通过。
- 完整 233 项单元测试通过，含参数化共 286 次执行；新增覆盖 8 种语言的东京离线命中、plural、简繁中文 script 解析，以及英语／日语／简中／繁中地名缓存隔离和共存。
- 简体中文原生侧边栏／国家城市导航 UI 流程通过。
- 英语、日语与繁体中文由 Apple Language 启动参数驱动的 UI 冒烟流程通过，证明不是应用内保存语言。
- Catalog JSON、占位符、目标语言完整性、Info.plist 和 git diff whitespace 检查通过；Release 包内 8 套语言资源与离线 TSV 均已核对。

尚未完成且不得隐去的发布项：全部非英语文案的全量母语审校（含简体与繁体中文）；Double-Length、Bounded String、RTL 伪语言检查；以及真实 Apple TV 上英语、日语和最长欧洲语言的 Focus、换行与电影感复核。它们不阻断当前多语言架构与功能落地，但在相应地区正式上架前必须完成。

母语审校的产品语气、术语、占位符约束、简繁中文地区差异、城市与国家名称只读边界、直接编辑 String Catalog 的分支/PR 流程及备用 `.xcloc` 方式，统一见 [Photo Earth 母语审校交接说明](LOCALIZATION_NATIVE_REVIEW_BRIEF_2026-09-11.md)。

### 12.5 2026-09-13 遥控器文案复核

- 已复核地球入口、直接操控、缩放工具条、记忆照片带、照片详情和设置中的 27 个按键／手势相关 key，覆盖英、德、西、法、意、日、简中、繁中 8 种语言。
- 屏幕上的短提示使用各语言自然、紧凑的“中央／中键”表达；辅助功能长提示使用 Apple 当地文档中的完整硬件名称，例如 clickpad center／touch surface、点按板中央／触控表面、觸控板中央／觸控表面。按键动作不再把英文 `Select` 机械翻译成“选择／選擇／選択”。术语依据包括 [Apple 简体中文 Siri Remote 说明](https://support.apple.com/zh-cn/102337)、[Apple 繁体中文 Apple TV 使用手册](https://support.apple.com/zh-tw/guide/tv/atvbe55a4b4e/tvos)、[Apple 德文 Siri Remote 说明](https://support.apple.com/de-de/102337) 与 [Apple 日文 Siri Remote 说明](https://support.apple.com/ja-jp/102337)。
- 操作结果按真实交互重新表述：短按中央查看照片；长按中央打开缩放控制，而不是直接“缩放地球”；缩放工具条明确只用左右键切换按钮；播放恢复提示明确指向实体播放／暂停键和屏幕上的“更多操作”。
- 清除了 String Catalog 中未再被源码引用的旧 `Press Select`／`Hold Select` 自动提取项，并为中心按键、触控表面、返回键等关键项补充 translator comment，避免后续翻译回退。
- 8 种语言逐一启动到 tvOS 地球界面的 UI 冒烟测试通过，并验证短按／长按提示存在且位于 1080p 电视安全区内。完整单元测试与 Release tvOS 无签名构建通过。这里仍是 Simulator 证据，不替代真实 Apple TV 上的观看距离和 VoiceOver 验收。
