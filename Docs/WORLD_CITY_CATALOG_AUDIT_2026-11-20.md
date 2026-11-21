# Photo Earth 世界旅行目的地与八种显示语言盘点

2026-11-20。以下为已发布目录、Mac 图库及两个本地候选方案的比较。正式匹配器在 Mac 上执行；tvOS 界面截断、切换耗时与新版运行性能未在本轮测量。

## 结论与验收决定

**采用「先确定城市归属，再补密度」的方案。** 现版能给 Mac 图库 98.5% 的定位素材返回城市，但在独立的 186 个公开景点上只认对 127 个。直接扩库提高了市中心命中率，同时把巴黎、伦敦等城市拆成了街区。加入可靠市界、保护原有高置信城市后，独立景点认对 169 个，原来认对的 127 个全部保住。建议进入共享目录工程验证，正式发布门槛仍未达到。

|验收指标|现版|只加密城市点|市界优先、保留近距离原匹配|
|---|---:|---:|---:|
|72 个 GeoNames 市中心命中正确旅行城市|50|72|71|
|186 个独立景点命中正确旅行城市|127（68.3%）|157（84.4%）|169（90.9%）|
|其中，入境前 20 个目的地的 121 个独立景点|81|104|113|
|额外留验的 68 个景点，匹配规则冻结后运行|51（75.0%）|59（86.8%）|62（91.2%）|
|186 个独立景点归错国家或地区|6|2|0|
|Mac 图库 30,525 项有效定位素材有城市名|30,067（98.5%）|30,223（99.0%）|30,208（99.0%）|
|GISCO 参照区内、且位于法美市界试验范围外的 3,598 项素材，城市名或同城别名一致|3,553|3,516|3,553|

186 个独立景点来自 57 个国家或地区，覆盖表中的全部 20 个优先目的地。185 个为 UNESCO 遗产点，1 个为香港天文台总部。跨城遗产按实际组成地点取坐标，例如马六甲和乔治市各取各的遗产点。城市以旅行时应展示的城市为准，伦敦塔归伦敦，街区不单列为城市。手选景点没有按客流加权，以上是指定样本成绩。72 个市中心与扩库候选同源，只宜作为目录完整性检查。[UNESCO 官方数据](https://data.unesco.org/explore/dataset/whc001/) · [马六甲与乔治市两个组成地点](https://whc.unesco.org/en/list/1223/maps/) · [香港天文台坐标](https://www.hko.gov.hk/en/cis/stn.htm) · [258 行公开坐标与逐点结果](WORLD_CITY_PUBLIC_COORDINATE_RESULTS_2026-11-20.csv)

### 高频目的地的大城市覆盖

在入境前 20 个目的地，从 GeoNames 选人口字段至少 10 万、类别为现存居民点或行政中心的 2,177 条记录。现版有 2,113 个点返回城市；核对同一区域码且城市名或别名相符，只有 **1,457 个（66.9%）**，其中 23 个返回其他区域码。英国 40/102、墨西哥 80/141、泰国 17/52、马来西亚 26/82。这一口径包含卫星城和行政中心，尤其在香港不能把它等同于用户期望看到的独立旅行城市。仅加密方案在同源数据上达到 2,169/2,177，放在独立景点上只有 157/186。[GeoNames 字段定义](https://download.geonames.org/export/dump/readme.txt) · [2,177 条逐城核验名单](WORLD_CITY_PRIORITY_DESTINATIONS_2026-11-20.csv)

对现版 1,457 个同区同名或别名命中的点，计算 GeoNames 代表坐标与返回的规范城市记录坐标间的球面距离。中位数 **1.19 km**，第 90 百分位 **5.44 km**，第 95 百分位 **9.13 km**，65 个相距超过 10 km。城市没有唯一的中心，此值衡量两套代表点的偏移；独立景点是否被归到正确城市才是照片归属验收。

### Mac 图库实测

本轮通过「照片」App 的只读脚本接口批量读取当前可见 55,991 项素材的定位字段。30,525 项有有效经纬度，其余 25,466 项不进入地名分母。有效值对应 23,124 对不重复坐标。以每张照片分别计数，现版 30,067 项有城市、455 项只有国家或地区、3 项未知；按不同坐标计数，22,769 个有城市、352 个只有国家或地区、3 个未知。这里计算每张素材坐标的标签；实际产品还会用到访代表坐标，用户相册排除和旅程门槛也会影响上屏的卡片。图库坐标仅用于本机计算，入库的是公开样本和汇总结果。

- **国家或地区的独立对照。** 将坐标与 Natural Earth 1:10m map units 离线相交。29,076 项落在有明确区域码的唯一地区；现版有 28,862 项区域码一致，214 项相异。另有 1,449 项没有唯一可用参照，单列。海岸线精度与地区定义会影响结果，214 项应读作差异待核。[Natural Earth 国家和地区数据](https://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-admin-0-countries/)
- **城市的独立对照。** 用法国本土 commune 和美国 Census place 的实际边界核对，515 项落入可对照区域。现版 379 项的城市与参照名或同城别名一致，加密方案为 393 项。市界原型在此直接使用这些边界，因此相同数据上的 515/515 只确认规则执行成功。另用 Eurostat 城市统计边界和美国 Census place 对照，5,431 项中现版为 5,259、加密方案为 4,143。部分欧洲统计城市比法定市域大；巴黎的统计范围甚至可覆盖凡尔赛，所以这组数字只说明归集层级改变。法美试验外的独立对照见上表。全图库逐张城市真值仍未知。[法国官方 commune 数据](https://www.data.gouv.fr/datasets/contours-administratifs) · [美国 Census place 边界](https://catalog.data.gov/dataset/2024-cartographic-boundary-file-shp-place-for-united-states-1-500000) · [Eurostat 城市统计边界](https://gisco-services.ec.europa.eu/distribution/v2/urau/download/)

### 方案如何比较

**只加密城市点。** 从本轮 GeoNames cities15000 取 PPL、PPLA、PPLA2–5、PPLC、PPLG。保留已有 GeoNames ID；在同区域基础名或英文名归一后相同、12 km 内只有一个匹配且尚未调整的底表记录上，用新代表点更新坐标；其余没有匹配的记录新增。添加 23,211 条，重新定位 5,440 条，候选 TSV 共 51,307 条、4,998,678 字节。这个实验仍用生产 Swift 匹配器。新条目只带基础名称，正式八语包和发布迁移另行验收。

**市界优先原型。** 在法国本土和美国已取得边界的地方，落入唯一市镇或 Census place 且与可用国家边界相容时取其名称。在其他区域，若坐标明确位于某国家或地区内部且距区域边缘保守估算超过 1 km，拒绝相冲突的国家；缺可信城市时保留国家。其余沿用旧城市。当旧结果没有城市，或旧规范代表点在 12 km 以外而新点在 6 km 以内时，再采用新城市。阈值用于试验；它们在新增的 68 点留验集运行前固定。原型比较的是归属标签，正式落地还须将市镇编号映射回稳定城市 ID、对齐别名并补齐翻译。正式 App 与 CDN 均维持原版本。

**剩余缺口。** 市界方案在 186 点中仍有 14 个错城、3 个只有国家。意大利皮恩扎仍返回锡耶纳，克罗地亚特罗吉尔仍返回斯普利特，日本平泉仍返回一关。以加密市中心全过为目标会漏掉这些问题。美国纽约也说明，单加一个代表点和在不同地标都能识别纽约是两项不同验收。

### 执行顺序和发布门槛

1. **在共享目录维护旅行城市身份。** 优先修法国、西班牙、葡萄牙、意大利、土耳其等已复现的错配，同时保住中、日、美现有身份。记录稳定城市 ID、所属区域、官方市镇 ID、城市与下辖区关系、八语首选名称及可接受别名。把入境排名与当地城市住宿/到访数据结合，小而高频的旅游城镇独立列入。
2. **地区边界先行，法定市镇与旅行城市分层。** 先在法美已有验证数据的地方试行，再逐国引入可用于产品发布、版本可追踪的边界。边界只决定归属，照片图钉保留 Photos 原坐标。郊区、岛屿、城区是否归入同一旅行城市应由稳定父子关系决定。共享包预检现行 16 MiB、100,000 行限制；边界按地区拆分的必要性根据 Apple TV 包体与内存实测决定。
3. **首版采用以下验收线。** 72 个既定市中心至少 71 个正确；186 个独立景点至少 95% 正确（至少 177 个），错国家为零；单列的 68 点留验集也至少 95%（至少 65 个）。保住现版正确的公开坐标；每次释放新增国家前，再加入从未参与调参的地标与边界点，单列各国结果。Mac 定位素材有城市的比例至少保持现版 98.5%，按不重复坐标复核；已确认的真实市镇参照子集不得退化。当前原型在主要景点指标上还差 8 个，在留验集还差 3 个。
4. **八语与城市身份一并验收。** 重点旅游城市逐个审校八语名称和简繁地区惯用名；显式脚本优先。切语言只换标签，不改变城市 ID、成员及真实坐标。模拟器验首页、城市墙及 Top Shelf；完成独立新样本、跨 App 一致性和电视性能验收后再发布共享资源。

本报告记录 2026-11-20 的历史 TSV 实验。现行 SQLite 匹配器使用 `python3 Scripts/verify_city_catalog_coverage.py --check-release` 复跑这些坐标和后续补充点；候选数据库可用 `--atlas` 指定。CSV 保存三种方案的逐点输出，私人图库明细不在其中。[复跑工具](../Scripts/verify_city_catalog_coverage.py) · [公开结果](WORLD_CITY_PUBLIC_COORDINATE_RESULTS_2026-11-20.csv)

## 旅行目的地覆盖

2025 年国际游客到访量前 20 个目的地全部在目录中有记录。取印度旅游部汇编表 1.1.2 所列顺序，原始统计来自 UN Tourism 2026 年 5 月晴雨表及其 7 月修订。个别目的地在表中有排名但没有当年人次数值。本表只采用其排序，香港按来源单列。国际入境统计用于排列补库优先级，国内旅行和具体城市需求需另看各地旅游局的城市住宿夜数或到访数据。[统计来源，第 9 页](https://www.tourism.gov.in/static/uploads/2026/09/a1ff37713ad3922f69778dca13aa65ab.pdf#page=9)

|到访排名|目的地|目录记录|到访排名|目的地|目录记录|
|---:|---|---:|---:|---|---:|
|1|法国|58|11|英国|57|
|2|西班牙|49|12|奥地利|9|
|3|美国|18,266|13|泰国|79|
|4|土耳其|83|14|葡萄牙|24|
|5|意大利|56|15|沙特阿拉伯|31|
|6|中国|2,037|16|阿联酋|8|
|7|墨西哥|189|17|马来西亚|32|
|8|日本|1,689|18|中国香港|1|
|9|希腊|30|19|荷兰|14|
|10|德国|58|20|波兰|24|

TSV 共 28,096 条代表点，经过正式解析器归并后有 28,049 个不同的目录身份。美国、中国、日本合计 21,992 条，占 78.3%。全球底表来自 Natural Earth，另外 20,754 个 GeoNames 编号全部分布在这三个国家。代表点还包含研究站等地点，记录数适合看投入分布，城市识别率应另行实测。[随包来源说明](../PhotoEarth/Resources/JourneyCatalogCredits.txt)

目录有 225 种有效的 ISO 3166-1 二字码。与 249 个代码比对，有 24 个代码没有记录，含泽西岛、荷属圣马丁、英属维尔京群岛和瑙鲁，亦含布韦岛等无常住人口地区。另有 12 条已有地点缺少代码，源数据使用 Somaliland、Northern Cyprus、Kosovo 三个英文区域名。当前界面在缺码时可能直接显示英文、以名称分组。建议为这类记录维护经审核的稳定区域标识与多语言名，并优先补有真实旅行需求的岛屿。[ISO 数据表](https://github.com/pycountry/pycountry/blob/main/src/pycountry/databases/iso3166-1.json) · [分组逻辑](../PhotoEarth/Domain/Models/PlaceCollection.swift)

## 城市中心坐标实测

从 GeoNames 获取 27 个国家或地区、72 个城市的公开代表坐标，包含大城市、沿海度假地、邻城、海岛及边境。用正式 Swift 解析器加载同一份生产 TSV 并调用 `label`。八种 App 语言在这 72 个点都给出一致的城市 ID 和区域码。逐点核对城市归属时承认 Macau/Macao、Kraków/Krakow 等同城异名。手选样本刻意覆盖容易出错的场景，不能据此外推整个图库的命中率。[GeoNames 数据下载](https://www.geonames.org/export/) · [正式匹配器](../PhotoEarth/Services/Geocoding/JourneyPlaceCatalog.swift)

|结果|点数|代表情况|
|---|---:|---|
|城市正确|50|国际到访量前四城市曼谷、香港、伦敦、澳门的中心点均命中。巴黎、东京、京都也命中。|
|同国错城|15|戛纳 → 尼斯、辛特拉 → 里斯本、纽约 → 霍博肯、会安 → 岘港。|
|错国家或地区|2|土耳其博德鲁姆 → 希腊科斯岛。泽西岛圣赫利尔 → 仅有法国估计。|
|只有正确国家|2|塞哥维亚只返回西班牙，图卢姆只返回墨西哥。|
|城市与国家均未返回|3|费特希耶、扎科帕内、亚伦。|

规则在距最近地点 45 公里内直接采用该点的城市和国家。45 公里外才走 200 公里内的国家估计，并检查其他国家是否距最近结果相差 50 公里以内。博德鲁姆落入第一段，从土耳其海岸被归入一个希腊岛。纽约的目录里已有 New York City，但在参考坐标处，霍博肯的代表点比纽约自己的代表点更近。两个问题分别需要补城市和改进归属判定。国家或城市卡会按解析结果归集照片，错城也会改变用户在照片墙看到的成员。[匹配分支](../PhotoEarth/Services/Geocoding/JourneyPlaceCatalog.swift) · [城市列表与照片范围](../PhotoEarth/Domain/Models/PlaceCollection.swift) · [Euromonitor 城市入境量](https://www.euromonitor.com/newsroom/press-releases/december-2025/euromonitor-international-unveils-worlds-top-100-city-destinations-for-2025)

## 八种语言

在本机 Foundation 上，225 个有效区域码 × 8 种语言均返回了非空、区别于代码的区域名称。城市取名使用独立的目录列。下表按正式解析后的 28,096 个代表点计数，包括别名继承的名称。同拼写可以是合适的当地名称，字段非空也不能代替译名审校。

|语言|有目标名称的记录|覆盖比例|
|---|---:|---:|
|英语|28,096|100.0%|
|德语|13,780|49.0%|
|西班牙语|14,440|51.4%|
|法语|14,435|51.4%|
|意大利语|14,295|50.9%|
|日语|15,803|56.2%|
|简体中文|21,239|75.6%|
|繁体中文|16,188|57.6%|

八列都有值的记录为 8,926 条，占 31.8%。英文列全部有值，但目前缺目标语言时直接选基础名。例如中国治多县的英文列为 `Zhidoi County`，基础名为 `Zhiduo`，日文列为空。原始 TSV 中，美国 18,266 条记录里只有 6,478 条有繁体中文，中国 2,037 条记录里只有 462 条有日文。法国现有 58 条均有日文及简繁中文，因此把「戛纳」译为任何语言都无法修复其坐标被归为尼斯的问题。[城市取名](../PhotoEarth/Services/Geocoding/JourneyPlaceCatalog.swift) · [目录](../PhotoEarth/Resources/JourneyCities.tsv)

**可复现的中文脚本错误。** 伦敦在 `zh-Hans` 下返回「伦敦」，在 `zh-Hans-TW`、`zh-Hans-HK` 下均返回「倫敦」。巴塞罗那在同样的组合下变成「巴塞隆納」。反方向直接传给匹配器 `zh-MO` 会得到简体「伦敦」，而 App 语言解析把澳门地区映射到繁体。原因是两处各自判断中文脚本，部分分支让地区覆盖了显式脚本。[App Locale 构造](../PhotoEarth/App/AppLocalization.swift) · [目录语言选择](../PhotoEarth/Services/Geocoding/JourneyPlaceCatalog.swift)

**切换语言的成本。** 生产路径把完整 Locale 存入扫描发布标识。只改语言也会命中重建分支，在同步阶段触发图库全量元数据枚举和后续整理。SQLite 已经有按语言分开的地名缓存，可在相同照片权限与相册范围内复用地点身份，只刷新名字。Top Shelf 快照保存的是发布时的标题，扩展读取现成文字，主 App 尚未重发快照时有显示旧语言的可能。这两项来自代码路径，未在 Apple TV 上做切换计时或画面复现。[发布条件](../PhotoEarth/Services/PhotoLibrary/TravelScanPolicy.swift) · [同步路径](../PhotoEarth/Services/PhotoLibrary/LibraryPreparationCoordinator.swift) · [SQLite 缓存](../PhotoEarth/Services/Persistence/TravelIndexStore.swift) · [Top Shelf 标题](../PhotoEarthTopShelf/ContentProvider.swift)

## 明细与复核

线上 TSV 与随包 TSV 已逐字节比对。版本为 `ne-geonames-cnjpus-20261022.1`，3,578,595 字节，SHA-256 为 `6de4ff1e1de35bee23d1f6d6730d1cbfe69479c38620bd47353a13c871f5e87d`。样本坐标取自本次下载的 `cities15000.zip`，SHA-256 为 `3413ab7e63ee1f7da441fc4d9c962fe31b569319430ab1e5b549f683fab8b84f`。下方列出实际输入，后续数据源更新也能复核。运行时调用 `JourneyCatalogResources.parse`，再用 `JourneyPlaceCatalog.label` 对每个坐标分别传入八种语言。[线上目录清单](https://lenspin-city-resources.pages.dev/catalog/manifest.json) · [GeoNames 下载](https://download.geonames.org/export/dump/)

<details>
<summary>72 个城市的输入坐标和实际输出</summary>

|预期地区|预期城市|GeoNames ID|纬度，经度|输出地区|输出城市（英文）|
|---|---|---:|---|---|---|
|TH|Bangkok|1609350|13.75398, 100.50144|TH|Bangkok|
|TH|Phuket|1151254|7.89059, 98.3981|TH|Phuket|
|TH|Chiang Mai|1153671|18.79038, 98.98468|TH|Chiang Mai|
|TH|Pattaya|1614295|12.93333, 100.88333|TH|Si Racha|
|TH|Krabi|1152633|8.07257, 98.91052|TH|Krabi|
|HK|Hong Kong|1819729|22.27832, 114.17469|HK|Hong Kong|
|MO|Macao|1821274|22.20056, 113.54611|MO|Macau|
|GB|London|2643743|51.50853, -0.12574|GB|London|
|GB|Oxford|2640729|51.75222, -1.25596|GB|Oxford|
|GB|Cambridge|2653941|52.2, 0.11667|GB|Cambridge|
|GB|Bath|2656173|51.3751, -2.36172|GB|Bath|
|GB|York|2633352|53.95763, -1.08271|GB|York|
|TR|Istanbul|745044|41.01384, 28.94966|TR|Istanbul|
|TR|Antalya|323777|36.90812, 30.69556|TR|Antalya|
|TR|Bodrum|320995|37.03833, 27.42917|GR|Kos|
|TR|Fethiye|314967|36.64038, 29.12758|—|—|
|AE|Dubai|292223|25.07725, 55.30927|AE|Dubai|
|SA|Mecca|104515|21.42664, 39.82563|SA|Mecca|
|FR|Paris|2988507|48.85341, 2.3488|FR|Paris|
|FR|Cannes|3028808|43.55135, 7.01275|FR|Nice|
|FR|Avignon|3035681|43.94834, 4.80892|FR|Nîmes|
|FR|Versailles|2969679|48.80359, 2.13424|FR|Versailles|
|FR|Annecy|3037543|45.90878, 6.12565|FR|Annecy|
|FR|Colmar|3024297|48.08078, 7.35584|FR|Mulhouse|
|FR|Nice|2990440|43.70313, 7.26608|FR|Nice|
|MY|Kuala Lumpur|1735161|3.1412, 101.68653|MY|Kuala Lumpur|
|MY|Malacca|1734759|2.196, 102.2405|MY|Melaka City|
|ES|Madrid|3117735|40.4165, -3.70256|ES|Madrid|
|ES|Barcelona|3128760|41.38879, 2.15899|ES|Barcelona|
|ES|Marbella|2514169|36.51543, -4.88583|ES|Marbella|
|ES|Benidorm|2521088|38.53816, -0.13098|ES|Alicante|
|ES|Toledo|2510409|39.8581, -4.02263|ES|Toledo|
|ES|Segovia|3109256|40.94808, -4.11839|ES|—|
|IT|Rome|3169070|41.89193, 12.51133|IT|Rome|
|IT|Florence|3176959|43.77925, 11.24626|IT|Florence|
|IT|Pisa|3170647|43.70853, 10.4036|IT|Pisa|
|IT|Siena|3166548|43.31822, 11.33064|IT|Siena|
|IT|Como|3178229|45.80819, 9.0832|IT|Como|
|IT|Venice|3164603|45.43713, 12.33265|IT|Venice|
|MX|Cancun|3531673|21.17429, -86.84656|MX|Cancun|
|MX|Playa del Carmen|3521342|20.6274, -87.07987|MX|San Miguel de Cozumel|
|MX|Tulum|3515040|20.21173, -87.46325|MX|—|
|DE|Berlin|2950159|52.52437, 13.41053|DE|Berlin|
|DE|Heidelberg|2907911|49.40768, 8.69079|DE|Heidelberg|
|DE|Bamberg|2952984|49.89873, 10.90067|DE|Coburg|
|AT|Vienna|2761369|48.20849, 16.37208|AT|Vienna|
|AT|Salzburg|2766824|47.79941, 13.04399|AT|Salzburg|
|AT|Innsbruck|2775220|47.26266, 11.39454|AT|Innsbruck|
|GR|Athens|264371|37.98376, 23.72784|GR|Athens|
|GR|Chania|260114|35.51124, 24.02921|GR|Chania|
|GR|Rhodes|400666|36.43556, 28.22199|GR|Rhodes|
|PT|Lisbon|2267057|38.72509, -9.1498|PT|Lisbon|
|PT|Sintra|2262912|38.80097, -9.37826|PT|Lisbon|
|PT|Lagos|2267226|37.10202, -8.67422|PT|Portimão|
|CN|Beijing|1816670|39.9075, 116.39723|CN|Beijing|
|CN|Shanghai|1796236|31.22222, 121.45806|CN|Shanghai|
|US|New York City|5128581|40.71427, -74.00597|US|Hoboken|
|US|Las Vegas|5506956|36.17497, -115.13722|US|North Las Vegas|
|JP|Tokyo|1850147|35.6895, 139.69171|JP|Tokyo|
|JP|Kyoto|1857910|35.02107, 135.75385|JP|Kyoto|
|NL|Amsterdam|2759794|52.37403, 4.88969|NL|Amsterdam|
|NL|Delft|2757345|52.00667, 4.35556|NL|The Hague|
|PL|Krakow|3094802|50.06143, 19.93658|PL|Kraków|
|PL|Zakopane|3080866|49.29899, 19.94885|—|—|
|VN|Hoi An|1580541|15.87944, 108.335|VN|Da Nang|
|ID|Ubud|1622846|-8.5098, 115.2654|ID|Denpasar|
|HR|Dubrovnik|3201047|42.64125, 18.10909|HR|Dubrovnik|
|HR|Split|3190261|43.50891, 16.43915|HR|Split|
|CH|Lucerne|2659811|47.05048, 8.30635|CH|Lucerne|
|CH|Montreux|2659601|46.43301, 6.91143|CH|Lausanne|
|JE|Saint Helier|3042091|49.18804, -2.10491|FR|—|
|NR|Yaren|7626461|-0.55085, 166.9252|—|—|

</details>

<details>
<summary>全部 249 个 ISO 区域的目录行数</summary>

此表只按 TSV 中显式代码统计，缺码的 12 条另计。0 表示没有使用该代码的代表点。

|代码|区域（ISO 英文短名）|记录数|
|---|---|---:|
|AD|Andorra|1|
|AE|United Arab Emirates|8|
|AF|Afghanistan|33|
|AG|Antigua and Barbuda|1|
|AI|Anguilla|0|
|AL|Albania|26|
|AM|Armenia|8|
|AO|Angola|49|
|AQ|Antarctica|40|
|AR|Argentina|158|
|AS|American Samoa|1|
|AT|Austria|9|
|AU|Australia|224|
|AW|Aruba|1|
|AX|Åland Islands|1|
|AZ|Azerbaijan|17|
|BA|Bosnia and Herzegovina|6|
|BB|Barbados|1|
|BD|Bangladesh|16|
|BE|Belgium|10|
|BF|Burkina Faso|32|
|BG|Bulgaria|18|
|BH|Bahrain|1|
|BI|Burundi|14|
|BJ|Benin|9|
|BL|Saint Barthélemy|0|
|BM|Bermuda|1|
|BN|Brunei Darussalam|1|
|BO|Bolivia, Plurinational State of|69|
|BQ|Bonaire, Sint Eustatius and Saba|0|
|BR|Brazil|392|
|BS|Bahamas|2|
|BT|Bhutan|4|
|BV|Bouvet Island|0|
|BW|Botswana|20|
|BY|Belarus|15|
|BZ|Belize|7|
|CA|Canada|255|
|CC|Cocos (Keeling) Islands|0|
|CD|Congo, The Democratic Republic of the|88|
|CF|Central African Republic|21|
|CG|Congo|17|
|CH|Switzerland|28|
|CI|Côte d'Ivoire|25|
|CK|Cook Islands|1|
|CL|Chile|84|
|CM|Cameroon|31|
|CN|China|2,037|
|CO|Colombia|72|
|CR|Costa Rica|13|
|CU|Cuba|26|
|CV|Cabo Verde|2|
|CW|Curaçao|1|
|CX|Christmas Island|0|
|CY|Cyprus|4|
|CZ|Czechia|12|
|DE|Germany|58|
|DJ|Djibouti|5|
|DK|Denmark|12|
|DM|Dominica|1|
|DO|Dominican Republic|31|
|DZ|Algeria|51|
|EC|Ecuador|37|
|EE|Estonia|7|
|EG|Egypt|42|
|EH|Western Sahara|1|
|ER|Eritrea|7|
|ES|Spain|49|
|ET|Ethiopia|34|
|FI|Finland|21|
|FJ|Fiji|4|
|FK|Falkland Islands (Malvinas)|2|
|FM|Micronesia, Federated States of|1|
|FO|Faroe Islands|2|
|FR|France|58|
|GA|Gabon|20|
|GB|United Kingdom|57|
|GD|Grenada|1|
|GE|Georgia|7|
|GF|French Guiana|7|
|GG|Guernsey|0|
|GH|Ghana|17|
|GI|Gibraltar|1|
|GL|Greenland|22|
|GM|Gambia|7|
|GN|Guinea|29|
|GP|Guadeloupe|2|
|GQ|Equatorial Guinea|6|
|GR|Greece|30|
|GS|South Georgia and the South Sandwich Islands|1|
|GT|Guatemala|26|
|GU|Guam|1|
|GW|Guinea-Bissau|8|
|GY|Guyana|10|
|HK|Hong Kong|1|
|HM|Heard Island and McDonald Islands|0|
|HN|Honduras|19|
|HR|Croatia|10|
|HT|Haiti|9|
|HU|Hungary|20|
|ID|Indonesia|105|
|IE|Ireland|15|
|IL|Israel|6|
|IM|Isle of Man|1|
|IN|India|214|
|IO|British Indian Ocean Territory|0|
|IQ|Iraq|27|
|IR|Iran, Islamic Republic of|63|
|IS|Iceland|9|
|IT|Italy|56|
|JE|Jersey|0|
|JM|Jamaica|14|
|JO|Jordan|9|
|JP|Japan|1,689|
|KE|Kenya|36|
|KG|Kyrgyzstan|14|
|KH|Cambodia|19|
|KI|Kiribati|1|
|KM|Comoros|1|
|KN|Saint Kitts and Nevis|1|
|KP|Korea, Democratic People's Republic of|27|
|KR|Korea, Republic of|28|
|KW|Kuwait|4|
|KY|Cayman Islands|1|
|KZ|Kazakhstan|96|
|LA|Lao People's Democratic Republic|14|
|LB|Lebanon|6|
|LC|Saint Lucia|1|
|LI|Liechtenstein|1|
|LK|Sri Lanka|14|
|LR|Liberia|13|
|LS|Lesotho|8|
|LT|Lithuania|5|
|LU|Luxembourg|3|
|LV|Latvia|6|
|LY|Libya|35|
|MA|Morocco|26|
|MC|Monaco|1|
|MD|Moldova, Republic of|5|
|ME|Montenegro|1|
|MF|Saint Martin (French part)|0|
|MG|Madagascar|28|
|MH|Marshall Islands|1|
|MK|North Macedonia|3|
|ML|Mali|30|
|MM|Myanmar|37|
|MN|Mongolia|24|
|MO|Macao|1|
|MP|Northern Mariana Islands|1|
|MQ|Martinique|1|
|MR|Mauritania|20|
|MS|Montserrat|0|
|MT|Malta|1|
|MU|Mauritius|2|
|MV|Maldives|1|
|MW|Malawi|20|
|MX|Mexico|189|
|MY|Malaysia|32|
|MZ|Mozambique|34|
|NA|Namibia|27|
|NC|New Caledonia|1|
|NE|Niger|16|
|NF|Norfolk Island|0|
|NG|Nigeria|68|
|NI|Nicaragua|19|
|NL|Netherlands|14|
|NO|Norway|34|
|NP|Nepal|17|
|NR|Nauru|0|
|NU|Niue|0|
|NZ|New Zealand|54|
|OM|Oman|10|
|PA|Panama|14|
|PE|Peru|89|
|PF|French Polynesia|1|
|PG|Papua New Guinea|23|
|PH|Philippines|38|
|PK|Pakistan|41|
|PL|Poland|24|
|PM|Saint Pierre and Miquelon|0|
|PN|Pitcairn|0|
|PR|Puerto Rico|4|
|PS|Palestine, State of|4|
|PT|Portugal|24|
|PW|Palau|2|
|PY|Paraguay|37|
|QA|Qatar|1|
|RE|Réunion|2|
|RO|Romania|41|
|RS|Serbia|7|
|RU|Russian Federation|585|
|RW|Rwanda|11|
|SA|Saudi Arabia|31|
|SB|Solomon Islands|3|
|SC|Seychelles|1|
|SD|Sudan|30|
|SE|Sweden|34|
|SG|Singapore|1|
|SH|Saint Helena, Ascension and Tristan da Cunha|0|
|SI|Slovenia|2|
|SJ|Svalbard and Jan Mayen|1|
|SK|Slovakia|7|
|SL|Sierra Leone|5|
|SM|San Marino|1|
|SN|Senegal|11|
|SO|Somalia|25|
|SR|Suriname|10|
|SS|South Sudan|15|
|ST|Sao Tome and Principe|2|
|SV|El Salvador|14|
|SX|Sint Maarten (Dutch part)|0|
|SY|Syrian Arab Republic|21|
|SZ|Eswatini|7|
|TC|Turks and Caicos Islands|1|
|TD|Chad|19|
|TF|French Southern Territories|0|
|TG|Togo|7|
|TH|Thailand|79|
|TJ|Tajikistan|9|
|TK|Tokelau|0|
|TL|Timor-Leste|1|
|TM|Turkmenistan|13|
|TN|Tunisia|26|
|TO|Tonga|2|
|TR|Türkiye|83|
|TT|Trinidad and Tobago|2|
|TV|Tuvalu|1|
|TW|Taiwan, Province of China|25|
|TZ|Tanzania, United Republic of|59|
|UA|Ukraine|49|
|UG|Uganda|43|
|UM|United States Minor Outlying Islands|0|
|US|United States|18,266|
|UY|Uruguay|32|
|UZ|Uzbekistan|29|
|VA|Holy See (Vatican City State)|1|
|VC|Saint Vincent and the Grenadines|1|
|VE|Venezuela, Bolivarian Republic of|50|
|VG|Virgin Islands, British|0|
|VI|Virgin Islands, U.S.|1|
|VN|Viet Nam|60|
|VU|Vanuatu|2|
|WF|Wallis and Futuna|0|
|WS|Samoa|1|
|YE|Yemen|20|
|YT|Mayotte|1|
|ZA|South Africa|72|
|ZM|Zambia|34|
|ZW|Zimbabwe|20|

</details>
