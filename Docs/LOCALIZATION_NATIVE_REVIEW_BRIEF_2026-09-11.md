# Photo Earth 母语审校交接说明

日期：2026-09-11  
状态：可交付母语审校；译者直接修改仓库中的 String Catalog；审校结果尚未回收  
适用版本：首批 8 种 App 语言（`en`、`ja`、`de`、`fr`、`es`、`it`、`zh-Hans`、`zh-Hant`）

## 1. 这次审校要解决什么

Photo Earth 的多语言工程已经接通，现有译文是首版工作稿，不应直接视为各市场的最终文案。本轮请母语者确认：

- 含义准确，没有把照片库、地点、扫描、索引或隐私含义翻错。
- 像自然的 Apple TV 产品文案，不像逐字翻译或地图后台术语。
- 保留 Photo Earth 克制、电影感、私人记忆感的语气。
- 按钮短而明确，电视远距离阅读时不拥挤。
- 复数、语序、敬语、人称、大小写和标点符合目标语言习惯。
- VoiceOver 等辅助功能文案单独朗读时仍然完整、自然。
- 权限说明准确表达“设备端处理、读取照片地点和日期、不修改照片库”。

当前范围包括：

- `Localizable.xcstrings`：216 个 UI、状态、错误及辅助功能语义 key。
- `InfoPlist.xcstrings`：2 个系统权限用途说明。
- 城市和国家名称：不属于本轮审校范围，严格只读，规则见第 9 节。

## 2. 可直接转发给审校者的英文说明

> **Photo Earth — Native-language review brief**
>
> Photo Earth is a native Apple TV app that turns a person’s geotagged photo library into a cinematic, private travel globe. It is an emotional viewing experience first, and a map or photo utility second.
>
> Please review every entry for your language directly in the repository's two Xcode String Catalog files: `PhotoEarth/Localizable.xcstrings` and `PhotoEarth/InfoPlist.xcstrings`. The current translation is a first-pass draft. You may rewrite it freely when needed, as long as the product meaning and placeholders remain intact.
>
> Aim for language that is warm, restrained, cinematic, concise, and natural on a television. Avoid literal wording, technical map language, marketing exaggeration, excessive exclamation marks, and wording that suggests photos leave the device or are modified.
>
> Buttons must be short and immediately understandable. Descriptive text may be emotional, but privacy, permission, error, scan, and accessibility text must remain precise. Review strings in context whenever screenshots or a test build are available.
>
> Do not edit tokens such as `%@`, `%1$@`, `%2$@`, or `%lld`. Numbered placeholders may be reordered to match your language. Do not translate the product name `Photo Earth`, the brand lockup `PHOTO EARTH`, Apple product names, identifiers, or file names.
>
> City and country names are outside the scope of this review. Do not edit Natural Earth data, generated TSV rows, MapKit place names, place IDs, region codes, coordinates, the catalog generator, or any place-name override. Photo Earth uses the names supplied by those upstream sources as-is.
>
> Work on the branch assigned to your language. Edit only the localized values for that language; do not edit English, another language, string keys, locale identifiers, JSON structure, or Swift source code. Commit your finished changes and open a pull request, or return the branch to the engineering coordinator. Use review comments only for phrases that need a product decision rather than a linguistic correction.

## 3. 语言与审校要求

| 语言 | Catalog 标识 | 建议审校者 | 特别关注 |
|---|---|---|---|
| 英语 | `en` | 美式或国际英语产品文案编辑 | 源文案清晰度、电影感、Apple TV 术语 |
| 日语 | `ja` | 日本本地 App/电视产品文案经验者 | 敬体一致、按钮长度、助词、行政后缀 |
| 德语 | `de` | 德国本地产品文案经验者 | `Sie/du` 一致、复合词长度、按钮换行 |
| 法语 | `fr` | 法国或国际法语产品文案经验者 | `vous` 语气、术语自然度、省略和标点 |
| 西班牙语 | `es` | 能处理国际西语的产品文案经验者 | `tú/usted` 不混用；标记明显地区差异 |
| 意大利语 | `it` | 意大利本地产品文案经验者 | 人称一致、自然动词、复数和按钮长度 |
| 简体中文 | `zh-Hans` | 中国大陆产品文案经验者 | “照片库”而非普通“图书馆”、记忆叙事、技术词准确 |
| 繁体中文 | `zh-Hant` | 台湾为主的繁体中文产品文案经验者 | 台湾 Apple 术语、繁简非机械转换、语气和行政后缀 |

当前只提供通用 `de/fr/es/it/ja` 语言版本，以及 script 级的 `zh-Hans/zh-Hant`，没有拆分地区变体。若审校者认为某个表达只能用于特定地区，请在反馈中注明，例如 `es-ES`、`es-419`、`fr-FR`、`fr-CA`、`zh-TW` 或 `zh-HK`，不要自行新增地区 Catalog。

### 3.1 审校进度记录

| 语言 | 审校者 | 母语/常住地区 | Catalog 全量审校 | 权限文案 | 日期 | 状态 |
|---|---|---|---|---|---|---|
| `en` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `ja` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `de` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `fr` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `es` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `it` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `zh-Hans` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |
| `zh-Hant` | 待填写 | 待填写 | 待完成 | 待完成 |  | 待审校 |

## 4. 产品语气

### 应当保留

- 私人、温暖、有余韵，但不过度煽情。
- 像一部由用户照片构成的旅行电影。
- 简洁安静，尤其是按钮、提示和 Focus 状态。
- 对隐私和失败状态保持直接、可信、无歧义。
- “地球被地点和回忆逐渐点亮”是一种核心叙事意象。

### 应当避免

- 把 App 写成地图管理工具、文件导入器或社交网络。
- 暗示会上传、复制、删除或修改用户照片。
- 把 `globe` 翻成玩具、水晶球或雪花球。
- 将 `Photo Library` 误译为普通书籍图书馆。
- 将 `memory` 一律机械翻译为计算机内存。
- 为追求诗意而牺牲按钮含义、权限准确性或辅助功能可理解性。
- 使用强烈销售话术、感叹号堆叠或过度宏大的承诺。

## 5. 核心术语表

下表解释英文源词在产品中的实际含义。目标语言不要求逐字对应，应优先使用母语者自然表达。

| 英文源词 | 中文意图说明 | 使用边界 |
|---|---|---|
| Photo Earth | 产品名称 | 不翻译；正文写作 `Photo Earth`，品牌锁定可写 `PHOTO EARTH` |
| travel globe | 由用户旅行照片构成的可交互地球 | 是地球体验，不是普通地图，也不是纪念品球体 |
| globe | 屏幕上的卫星影像地球 | 与 `world`、`map` 区分 |
| memory / memories | 一张照片所承载的个人时刻或回忆 | 在数量文案中仍要自然、可计数 |
| photo / photos | 实际照片资产 | 不要与 memory 在所有场景中强行互换 |
| place | 由照片坐标聚类出的地点 | 不一定已经有城市名 |
| city | 已解析或可靠匹配出的城市 | 不等于任意 place |
| country | 由地理编码或 ISO region code 得出的国家/地区显示名 | 不作为地点稳定 ID |
| recent arrivals | 最近到访的地点集合 | 不是实时航班“抵达”列表 |
| explore / explore globe | 进入直接操控地球 | 表达发现和浏览，不是编辑 |
| photo wall | 当前地点或视野中的照片集合页 | 不是实体墙，也不是社交墙 |
| photo information | 单张照片的时间、地点、尺寸和收藏状态 | 简洁的信息面板 |
| photo library | Apple 系统照片库 | 使用目标市场惯用的 Apple 平台术语 |
| scan / organize | 读取轻量元数据并在设备端生成索引 | 不下载全部原图，不修改照片 |
| index | 可删除、可重建的本地派生数据 | 面向普通用户时尽量避免数据库术语 |
| place name | 城市和国家显示名 | 与坐标、地点 ID 分离 |
| location pending | 暂时没有可靠的城市/国家名 | 不表示照片丢失或扫描失败 |
| light / alight | 地点和回忆在地球上被逐渐点亮 | 情绪意象，不是照明功能 |
| Return to Globe | 从照片页返回同一地球上下文 | 不应被理解成重置或退出 App |
| Apple TV Settings | Apple TV 的系统设置 | 使用 Apple 在目标语言中的正式产品术语 |

## 6. 必须保持不变的技术内容

### 6.1 占位符

不得删除、翻译或改变类型：

- `%@`：一段已格式化文本。
- `%1$@`、`%2$@`、`%3$@`：可以按目标语言语序重新排列，但每个编号必须保留。
- `%lld`：整数数量；plural variation 中必须保留。

示例：

```text
English: Complete place names %1$@ / %2$@ · %3$@ remaining
```

目标语言可以把 `%3$@` 提前，但不能改成 `%@`、`%d` 或直接写死数字。

### 6.2 名称与系统术语

- 不翻译 `Photo Earth`、`PHOTO EARTH`。
- Apple TV、iCloud Photos 等产品名采用 Apple 在目标语言中的官方写法。
- SF Symbols 名、accessibility identifier、数据库字段和文件名不是文案，不应修改。
- `·`、`…` 等符号可以按目标语言排版习惯调整，但要保留电视界面的克制感。

### 6.3 隐私事实

译文不能改变以下事实：

- App 读取照片的地点和拍摄日期来生成旅行地球。
- 默认在 Apple TV 设备端组织地点和索引。
- 不修改、删除用户的照片。
- 需要显示时才通过系统照片库读取合适尺寸的图片。
- 不应承诺所有原图永远完全离线；iCloud Photos 可能由 PhotoKit 按需获取图片。

## 7. 按页面审校

建议按以下顺序结合截图或测试版本检查：

1. 首次启动与照片权限：`welcome.*`、`permission.*`、`InfoPlist.xcstrings`。
2. 扫描与地点准备：`scanning.*`、`preparation.*`、`ready.*`、`empty_library.*`。
3. 首页与侧边栏：`home.*`、`sidebar.*`、`place_card.*`。
4. 地球直接操控与缩放：`globe.*`、`memory_strip.*`。
5. 最近到访、国家与城市：`library.*`、`place.*`。
6. 照片墙与详情：`wall.*`、`detail.*`、`photo.*`、`gallery.*`。
7. 设置与隐私：`settings.*`。
8. 错误、通用操作和状态：`error.*`、`common.*`、`state.*`。
9. 数量和复数：`count.*`。

每个页面至少检查：标题、说明、按钮、加载状态、空状态、失败状态、返回文案和辅助功能朗读。

## 8. 高风险审校项

以下内容优先级最高：

### P0：必须修正后才能发布

- 照片权限用途说明和隐私陈述。
- 删除、修改、上传、下载、同步等动作含义被翻错。
- 按钮表达的动作与实际行为不一致。
- `%@`、`%lld` 等占位符缺失或类型改变。
- 单复数错误导致数量句不成立。
- VoiceOver 文案无法独立理解。
- 文案可能让用户误以为 App 会改变 iCloud Photos 内容。

### P1：影响产品品质

- 首页、地球、记忆、地点等核心术语不统一。
- 逐字翻译、机器翻译感、敬语或人称混乱。
- 按钮太长、电视上容易截断或形成三行以上。
- “点亮世界”“私人旅行地球”等情绪文案显得夸张或生硬。

### P2：可在最终润色阶段处理

- 标点、大小写、空格和细微风格偏好。
- 不影响理解的同义词选择。
- 少见错误状态的语气优化。

## 9. 城市与国家名称是严格只读数据

城市和国家名称不属于本轮专业翻译或审校范围，译者既不修改，也不抽检验收。

- 离线城市名从 Natural Earth 5.1.2 已处理的 `NAME_*` 字段抽取，应用没有自行翻译。
- MapKit 在线解析出的城市和国家名使用 MapKit 返回值。
- 国家 fallback 由 Apple `Locale.localizedString(forRegionCode:)` 或 Natural Earth 数据提供。
- 工程不建立人工翻译表或 place-name override，不用译者意见覆盖上游名称。

译者不得修改或在 PR 中包含以下内容：

- `PhotoEarth/Resources/NaturalEarthPopulatedPlaces.tsv`。
- `Scripts/generate_offline_place_catalog.py` 及其字段映射。
- Natural Earth ID、ISO region code、经纬度或任何城市名称字段。
- MapKit 地名结果、地名缓存结构或离线地名选择逻辑。

如果审校过程中看到不熟悉、历史性或地区敏感的地名，保持原样即可，不将其计为翻译缺陷，也不阻断本轮 UI 文案验收。

## 10. 审校记录与问题模板

每位审校者请填写基本信息：

```text
语言与地区：
审校者母语及常住地区：
审校日期：
是否看过实际 Apple TV 画面：是 / 否
是否完成全部 216 个 UI key：是 / 否
是否完成 2 个权限说明：是 / 否
需要产品决定的问题数：
```

普通语言修订直接写入 String Catalog，不需要再抄写一份修改表。只有需要产品决定的歧义或译者无法通过语言判断的问题需要单独记录。城市和国家名称不进入问题表。

问题记录：

| 优先级 | String key | 当前译文 | 建议译文 | 修改原因 | 页面或上下文 |
|---|---|---|---|---|---|
| P0/P1/P2 | `settings.privacy_message` |  |  |  | 设置 → 照片和隐私 |

整体反馈：

```text
核心术语是否统一：
整体语气是否自然：
最需要重写的页面：
可能产生歧义的产品行为：
疑似截断或过长的文案：
地区差异建议：
其他备注：
```

## 11. 译者直接修改仓库配置

### 11.1 唯一允许修改的本地化文件

普通 App 文案只改以下两个文件：

- [`PhotoEarth/Localizable.xcstrings`](../PhotoEarth/Localizable.xcstrings)：216 个 UI、状态、错误和辅助功能 key。
- [`PhotoEarth/InfoPlist.xcstrings`](../PhotoEarth/InfoPlist.xcstrings)：2 个系统权限用途说明。

这些 String Catalog 是 App 构建使用的源配置。译者不需要把修改另交为 Excel，也不需要等待工程人员二次抄入。禁止为了翻译文案修改 Swift、Info.plist、项目文件或 `NaturalEarthPopulatedPlaces.tsv`。

### 11.2 分支与提交方式

每位译者使用独立分支，只负责一种语言，建议命名：

```text
localization/review-en
localization/review-ja
localization/review-de
localization/review-fr
localization/review-es
localization/review-it
localization/review-zh-hans
localization/review-zh-hant
```

工作步骤：

1. 英语文案编辑先完成并冻结 `en` source copy；其他语言从负责人指定的同一基线 commit 创建语言分支。
2. 打开 `PhotoEarth.xcodeproj`，使用 Xcode 的 String Catalog 编辑器打开两个 `.xcstrings` 文件。
3. 筛选自己的语言，逐项修改译文；同时检查 plural variants 和权限说明。
4. 保存后查看 Git diff，确认只改了自己的语言值。
5. 提交一个或少量清晰 commit，并创建 PR；不要在审校期间合并主分支或重排整个 JSON 文件。
6. PR 描述填写审校者语言/地区、完成范围、是否看过电视画面和需要产品决定的问题。

多个语言分支可以并行审校，但两个 `.xcstrings` 都是包含全部语言的共享 JSON，连续合并 PR 时可能发生文本冲突。译者不要通过删除或覆盖其他 locale 来解决冲突；由工程负责人按目标 locale 合并。英语冻结后如仍修改含义，受影响的其他语言必须重新审校。

建议 commit message：

```text
Review Japanese localization
```

### 11.3 可以改与不可以改的内容

译者可以修改：

- 自己语言下普通条目的 `stringUnit.value`。
- 自己语言下 plural `one`、`other` 等已有类别中的 `stringUnit.value`。
- 为符合母语语序重新排列 `%1$@`、`%2$@` 等带编号占位符。

译者不可以修改：

- 顶层 `sourceLanguage`，当前固定为 `en`。
- `strings` 下的 key，例如 `settings.privacy_message`。
- 除本人被分配的目标语言外，其他语言下的任何值；只有英语 source-copy 审校者可以修改 `en` 的译文值。
- `localizations` 的 locale 标识，例如 `ja`、`de`、`zh-Hant`。
- `extractionState`、`state`、`variations`、`plural`、`stringUnit` 等结构字段。
- 不属于自己语言的 plural 类别；如认为类别缺失，应写 PR comment 交给工程侧处理。
- 第 6 节列出的格式占位符、产品名和技术标识。

如果译者使用文本编辑器直接修改 JSON，只能修改目标语言对象中的 `"value"` 字符串，并确保转义和 JSON 语法有效。例如日语译者只可以修改下面标出的值：

```json
"ja": {
  "stringUnit": {
    "state": "translated",
    "value": "← 只修改这里的日语译文"
  }
}
```

Plural 条目同理，只修改本语言已有的各个 `stringUnit.value`：

```json
"de": {
  "variations": {
    "plural": {
      "one": {
        "stringUnit": {
          "state": "translated",
          "value": "%lld …"
        }
      },
      "other": {
        "stringUnit": {
          "state": "translated",
          "value": "%lld …"
        }
      }
    }
  }
}
```

### 11.4 PR 自检清单

提交前由译者确认：

- 两个 Catalog 都已全量检查，不只是首页示例。
- Git diff 中没有 Swift、项目文件、离线 TSV 或其他语言的改动。
- 所有占位符的编号、数量和类型保持不变。
- 没有把数字写死来替代 `%lld`。
- `Photo Earth`、`PHOTO EARTH` 和 Apple 产品名符合第 6 节规则。
- 权限、错误与辅助功能文案准确，不能为了诗意改变产品行为。
- 已在 PR 中列出需要产品决定的问题；没有把未决定事项擅自写成事实。

### 11.5 备用方式

只有当译者无法访问 Git 仓库或无法可靠编辑 String Catalog 时，才使用 Xcode 的 `.xcloc` Export/Import 流程。该方式是兼容备用方案，不是本项目本轮审校的默认交付方式。

Apple String Catalog 参考：

- [Localizing and varying text with a string catalog](https://developer.apple.com/documentation/xcode/localizing-and-varying-text-with-a-string-catalog)
- [Exporting localizations](https://developer.apple.com/documentation/xcode/exporting-localizations)
- [Importing localizations](https://developer.apple.com/documentation/xcode/importing-localizations)

## 12. 应随审校分支一起提供的上下文

每位译者除仓库分支和本文档外，还应获得以下画面，最好包含聚焦态和非聚焦态：

- 首次启动和照片权限前说明。
- 扫描进行中、暂停、部分完成和失败状态。
- 地球首页、最近抵达 Dock 和更多地点货架。
- 地球操控提示、缩放工具条和边界提示。
- 当前视野照片墙、无照片状态和分页状态。
- 单张照片详情及信息面板。
- 最近到访、国家列表、城市列表。
- 设置页和重新扫描/重建入口。

截图和视频中只能使用公开 Demo 素材，不得包含真实用户的照片、精确坐标或照片标识。

## 13. 工程合并前的验收

每种语言的 PR 合并前，工程侧必须完成：

- 检查 216 个 UI key 和 2 个权限 key 是否仍然完整。
- 检查所有占位符的数量、编号和类型。
- 构建 String Catalog，确认 `.strings`、`.stringsdict` 和 `InfoPlist.strings` 正常生成。
- 运行目标语言启动和主要页面 UI 流程。
- 检查单数、复数、0、1、2 和较大数量。
- 执行 Double-Length、Bounded String 和 RTL 伪语言布局测试。
- 在真实 Apple TV 上检查长文案、Focus、换行、法务净空和电影感。
- 对 P0/P1 反馈逐条关闭；未解决项记录明确的产品决定。

## 14. 当前工程资料

- UI String Catalog：[`PhotoEarth/Localizable.xcstrings`](../PhotoEarth/Localizable.xcstrings)
- 权限 String Catalog：[`PhotoEarth/InfoPlist.xcstrings`](../PhotoEarth/InfoPlist.xcstrings)
- 多语言与离线地名方案：[`Docs/LOCALIZATION_PLAN_2026-09-11.md`](LOCALIZATION_PLAN_2026-09-11.md)
- 离线城市数据：[`PhotoEarth/Resources/NaturalEarthPopulatedPlaces.tsv`](../PhotoEarth/Resources/NaturalEarthPopulatedPlaces.tsv)
- 离线城市生成脚本：[`Scripts/generate_offline_place_catalog.py`](../Scripts/generate_offline_place_catalog.py)

本轮审校完成的定义不是“看过几条示例”，而是每种目标语言的完整 Catalog 已由合适的母语者直接修改并提交，权限和辅助功能文案无 P0 问题，核心术语一致，并经过实际电视界面验证。
