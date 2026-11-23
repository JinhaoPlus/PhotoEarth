# PHOTO EARTH 八种语言的界面文案审校

每种语言由独立模型代理审阅。以当前中英文为参照，把按钮、相邻说明、设置项、权限弹窗和 VoiceOver 朗读放回实际操作中核对。检查了主 App 和 Apple TV 主屏扩展的四份 String Catalog，并对照了九组配乐分类在曲库配置和 App 内的名称。审校依据是产品行为与语言用法，尚未做当地母语用户访谈。

## 各语言最影响理解的改动

| 语言 | 用户原先会遇到什么 | 现在的表达 |
| --- | --- | --- |
| 简体中文 | 设置说「选中图标」即可预览城市照片，容易让人按下中键打开 App。扫描画面上的「3 / 8 个地点」也没说明在数什么。 | 写明把遥控器焦点移到主屏图标即可预览。扫描进度显示「已确定地名：3 / 8」。 |
| 英语 | 已购买用户仍要进入 *Buy Full Version* 才能看状态。购买用 *journey*，选择器却将同一段旅程称为 *trip*。 | 已购用户看到 *Full Version*，可购买时的入口仍叫 *Buy Full Version*，实际付款按钮为 *Buy Full Version · One-Time Purchase*。购买、示例和放映选择统一用 *trip*。 |
| 日语 | 暂停时还会出现「写真情報を確認中です」，像是扫描仍在继续。地图按钮「現在の画面に切り替え」也没说切换什么。 | 暂停时显示「写真情報の確認はまだ完了していません」。地图按钮用「この範囲の写真を表示」，指向将会显示的照片。 |
| 德语 | 照片地图入口叫 *Kartenrückblick*，容易理解成地图的历史回顾。遥控器的 *Bewegen* 也不容易与按方向键转动区分。 | 入口用 *Fotokarte*，触摸拖动用 *Ziehen*，按方向键转动用 *Drehen*。 |
| 法语 | 恢复购买无结果时写 *Aucun achat actif*，让买断用户以为购买可能失效。扫描进度中的 *prêts à explorer* 接在 *1 visite* 后面又产生语法错误。 | 改为 *Aucun achat à restaurer pour ce compte.*。进度以 *À explorer* 开头，再读出项目数和到访数，单复数都成立。 |
| 西班牙语 | 页面标题是 *Ámbito del escaneo*，加载失败却要求重新打开 *el alcance del análisis*。用户找不到提示中所指的页面。 | 入口和恢复提示都用 *Opciones de análisis*。通用西语沿用目前的 Apple TV 系统术语，如 *Ajustes* 和 *mando*。 |
| 意大利语 | 隐藏途经照片时，*Il filtro esclude i preferiti* 既可能是收藏免于筛选，也可能是收藏会被隐藏。 | 写明结果 *I preferiti restano visibili.*。地图入口用 *Mappa delle foto*，从地图返回照片集合用 *Torna alla galleria*。 |
| 繁体中文 | 「示例旅程」带有简中直译痕迹。Apple TV 主画面提示用「選取圖像」，无法判断是移动焦点还是按下遥控器。 | 采用台湾常见的「範例旅程」，主画面提示写明「把焦點移到 App 圖像上」。恢复购买统一为「回復購買項目」。 |

## 跨页面核对

- **试用与免费旅程。** 用户可以在试用前或到期后首次领取免费旅程，已领取的会保留。购买页现在说明到期后仍可免费浏览、放映一段旅程。尚未领取时，首页会解释最先打开的那段会保留。七天、不会自动扣费、一次购买永久解锁，分别保留在对应说明里。[资格判断](../PhotoEarth/Features/Globe/GlobeView.swift) · [购买页](../PhotoEarth/Features/Onboarding/PurchaseGate.swift)
- **地图与放映。** 地图操作会解除城市筛选并刷新当前范围内的照片。放映准备页分别报告「已检查」和「可播放」的数量。胶片栏可以选择照片或视频。关闭背景音乐时单独翻译完整状态，例如西语 *Sin música de fondo*，避免通用开关状态的性别与「音乐」不一致，也能与视频原声区分。[地图操作](../PhotoEarth/Features/Globe/GlobeView.swift) · [放映画面](../PhotoEarth/Features/Slideshow/EarthSlideshowView.swift)
- **设置中的政策入口。** 日、德、法、西、意语入口标明将打开英文，繁中入口标明「簡體中文」。本轮审校仅涉及入口。[设置阅读页](../PhotoEarth/Features/Settings/SettingsReferenceView.swift)
- **保留的表达。** 「未知地点@日本」及其外语对应格式是项目对匿名地点的明确约定。本轮保留。若调整这项约定，可在简中显示「未知地点（日本）」，为 VoiceOver 单独朗读「日本，地点名称未知」。[地点列表规则](../rules/navigation.md)

## 验证

四份目录的 419 个可译条目都有八语值。逐条检查了格式占位符，并核对主 App 与 Top Shelf 的地球入口使用相同译名。Apple TV 模拟器通过了八语地图工具条、遥控提示与放映入口测试，以及法语选中 1,000 段旅程、关闭背景音乐和设置内购买状态等用例。另用本地 StoreKit 测试跑通试用、到期、恢复购买、买断与退款。未进行 Apple TV 真机验收。
