# 多语言、地名显示与辅助功能

## UI 与测试语言

- UI、状态、错误、辅助功能和权限用途说明使用 Xcode String Catalog；英语作为开发源语言，首批支持英语、日语、德语、法语、西语、意大利语、简体中文和繁体中文。应用只跟随 Apple TV 系统为当前 App 解析的系统／App Language，不提供应用内语言选择器，不在 UserDefaults 或 iCloud KVS 保存独立语言偏好；无匹配语言时回退英语。MapKit、离线地名和 UI 必须使用同一个已解析 Locale。
- 开发用 Apple TV 或 Simulator 可以在 Xcode Scheme 的 Run Options 中临时指定 App Language / App Region；自动化只允许在 `PhotoEarthUITests` 中使用 `-AppleLanguages` / `-AppleLocale` 启动参数。正式 App target 不实现隐藏语言选择器、启动参数覆盖或语言偏好持久化，Release 用户只能使用 Apple TV 的系统／App Language 配置。
- 日期、数字、复数和单位使用 Foundation FormatStyle 与 String Catalog plural variations，不固定 `zh_CN`，不拼接“张／个／米”等语言片段，也不持久化已翻译的状态文案。

- 聚类、照片、地点与旅程身份必须与显示语言解耦。“地名待完善”等是本地化显示状态，不得作为地点事实或通过中文占位文案判断解析完整性。国家与地区按稳定区域标识组织。常规地区使用 ISO 区域码，科索沃使用 CLDR 的 XK；原始目录没有二字码的索马里兰与北塞浦路斯保留来源地区语义，以 Natural Earth 的 ADM0_A3 区分。城市／集合查询保存稳定 place ID 范围。

- 示例旅程、Simulator 十城目录及 UI 测试不得依赖中文城市名或中文按钮名。自动化改用稳定 accessibility identifier，并覆盖目标语言、复数、地名 fallback、缓存隔离、迁移及 Xcode 伪语言布局。

- 地名使用离线城市目录的本地化标题，并与应用解析后的 Locale 一致。稳定的城市／到访 ID 与区域标识独立于显示语言。语言变化在既有索引内更新地名。显式简繁脚本优先于地区；有地区惯用名时跟随地区。Top Shelf 读取发布快照中的多语言城市标题，和主 App 使用同一身份。台湾、香港、澳门的专用名只用于对应地区。城市译名按同一实体与语言来源核查；公开原名、英文回退、字形转换和有当地用例的译名分别记录。
- 城市与国家或地区同行出现时，城市在前，空一格后接较小的灰色国家名。两者同名时只显示一次。首页最近到访、按年排列的旅程卡片与其他页面共用这一排版。
- 同屏文字按上下文取舍。分组标题承担共同的年月或国家，卡片保留辨认这一项所需的差异；页头、页尾和设置说明只补充当前操作需要的信息。单独聚焦的控件仍提供完整的无障碍名称。照片与视频合计使用本地化项目数；已知媒体类型时使用对应名称和量词。空状态区分无匹配、已过滤与预览暂缺，按当前状态提供恢复动作。
- 中文交互文案使用自然的「旅行地球」「地点名称」「当前画面」等词，面向用户说明动作、原因及如何恢复。避免把索引、瓦片、生命周期等实现术语直接显示给用户。
- 交互控件提供本地化 VoiceOver 名称，测试按稳定 accessibility identifier 寻址。用系统 Reduce Motion／Reduce Transparency 验证主要页面。
- 现行离线地名规则见 [到访与城市](places-covers.md)。翻译方法及审校范围见 [本地化方案](../Docs/LOCALIZATION_PLAN_2026-09-11.md) 和 [母语审校交接](../Docs/LOCALIZATION_NATIVE_REVIEW_BRIEF_2026-09-11.md)。
