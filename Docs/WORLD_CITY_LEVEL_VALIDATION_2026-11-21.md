# 旅行城市归组验收 · 2026-11-21

Photo Earth 与 LensPin 的打包目录使用同一份 `world-atlas-20261121.5`，SHA-256 为 `f1439f16a3793bfb2b2e0e18aff9f631bbf771dd7d8ec8ac10a46e8bd04a5427`。本轮使用公开坐标，通过两个产品的 Swift 城市解析入口比对。验证脚本不读取照片。

| 样本 | .4 | .5 |
| --- | ---: | ---: |
| 原有 289 处城市中心和地标 | 289/289 | 289/289 |
| 对照 Apple 城市字段及济源例外的公开点 | 8/22 | 22/22 |
| 法国、德国及迪拜的市内行政区、街区 | 50/58 | 58/58 |
| 法国、英国、德国邻近独立城市 | 9/9 | 9/9 |
| 20 个优先目的地的城市参考点，原地名标准 | 2,075/2,177 | 1,774/2,177 |
| 同一批参考点，允许有依据的父城市 | 2,133/2,177 | 2,136/2,177 |

原地名标准沿用 GeoNames 的参考名称和别名。父城市标准另核对参考实体、发布源中的父城市 ID、国家或地区和本次实际命中。本次有 362 个参考点通过已核实的父城市关系命中。用同一批关系回判 .4，其中已有 58 个参考点返回正确的父城市。.5 比 .4 新增 3 个命中，.4 原已命中的点全部保留。仍有 38 个点返回其他城市，3 个点的国家或地区不同。逐点表含两版结果、原始分与城市层级分。[2,177 点明细](WORLD_CITY_LEVEL_PRIORITY_2026-11-21.csv.gz)

### 城市层级与名称

2026-11-21 在 macOS 27.0.1 用 MapKit 的 `MKReverseGeocodingRequest`，以英文读取 `addressRepresentations.cityName`。22 个返回结果中，21 个与目录指向同一城市，包括万州、奉节归重庆，昆山归苏州，阳朔归桂林。台北一项保留 Apple 的英文返回值 Taibei 和目录用名 Taipei。济源的上游字段返回省名 Henan，目录保留当地政府确认的城市济源。巴黎、威斯敏斯特和布鲁克林的本次 SDK 请求返回 `MKErrorDomain 4`，未计入 Apple 样本。[Apple 样本及原字段](WORLD_APPLE_CITY_CHECKPOINTS_2026-11-21.csv) · [Apple 城市字段](https://developer.apple.com/documentation/mapkit/mkaddressrepresentations/cityname) · [济源市政府](https://www.jiyuan.gov.cn/shiqing/jygk/ls/t385810.html)

法国 IGN 记录通过父市镇法定代码区分巴黎 20 区、马赛 16 区和里昂 9 区。45 处区内坐标在 .4 已经显示所属城市。新增公开验收还包含巴黎 4 个街区、德国 5 个曾被直接显示的街区、迪拜 4 个街区，以及边界外 9 个独立城市。49 个可从旧目录保存的街区 ID 通过 13 种语言或地区设置逐一核对了首页货架的显示。在这批街区中，迪拜的 Bur Dubai 在 .4 已显示迪拜，另三个公开点在 .5 改为迪拜。法国国家地址库另对照了 89 个公开点，88 个有邻近门牌，`city` 字段均符合预期。马赛第九区的面内样点未返回附近门牌。[分区及邻市的坐标与来源](WORLD_CITY_SUBDIVISION_CHECKPOINTS_2026-11-21.csv) · [法国市镇与行政区法律关系](https://www.legifrance.gouv.fr/codes/id/LEGISCTA000006192294) · [巴黎行政街区](https://opendata.paris.fr/explore/dataset/quartier_paris/) · [法国国家地址库](https://adresse.data.gouv.fr/)

### 历史兼容与产品一致性

.3 与 .4 在整套冻结样本上的地区、城市 ID、匹配来源、城市名和国家名逐字段相同。以这套结果比对 .5 的 1,258 个坐标 × 8 种语言和 56,191 个英语密集样点，产生 3,109 条预期变动，其中 264 条来自八语组、2,845 条来自英语密集样本。每条变动均可回指已审核的源关系，其他历史变动为 0。新增 Apple 公开点也逐一通过两个产品的八语入口。两端共比对 66,431 条，产品差异为 0。[历史变化逐项表](WORLD_CITY_LEVEL_MIGRATION_2026-11-21.tsv.gz) · [复跑命令](../Scripts/README.md)

纽约市和大伦敦部分地址有更具体的 locality。Apple 零售站的结构化地址分别给出 Brooklyn、Elmhurst、Bromley，这些地址字段与 MapKit 的 `cityName` 可独立核对。此轮未据大伦敦边界或 Borough 字段成批生成归并。[Brooklyn](https://www.apple.com/retail/williamsburg/) · [Elmhurst](https://www.apple.com/retail/queenscenter/) · [Bromley](https://www.apple.com/uk/retail/bromley/)

### 中国和法国以外的复核

重新运行了随包数据库的公开坐标验收。378 个公开断言涉及 63 个国家和地区代码，其中原有的城市中心和地标覆盖 62 个。这些城市中心和地标可以验证已有坐标的匹配，城区、城市边界和邻市归属仍需单独取样。同一批 20 个优先目的地里，中国及港澳台和法国以外的 17 个目的地有 1,416 个参考点，1,382 个在城市层级吻合，34 个与 GeoNames 的城市标注不同。本次新增归属表中，该范围有 122 条记录，分布在德国、加拿大、巴西、波兰、美国、意大利、日本、阿联酋和西班牙。[公开坐标](WORLD_CITY_PUBLIC_COORDINATE_RESULTS_2026-11-20.csv) · [分区与独立城市](WORLD_CITY_SUBDIVISION_CHECKPOINTS_2026-11-21.csv) · [优先目的地逐点结果](WORLD_CITY_LEVEL_PRIORITY_2026-11-21.csv.gz)

在开发机另外向 Apple MapKit 查询了 16 个国家的 20 个公开坐标，包括日本东京港区、韩国首尔江南、新加坡滨海湾、泰国曼谷都实区、马来西亚吉隆坡武吉免登、英国威斯敏斯特和美国布鲁克林。20 次均返回 `MKErrorDomain 4`，没有取得可用于确认的 `cityName`。本地生产解析器显示都实区归曼谷、武吉免登归吉隆坡，符合当地政府资料。纽约和伦敦样本的 Apple 城市字段仍未确认。[曼谷都实区办公室](https://webportal.bangkok.go.th/dusit/contact) · [吉隆坡市政局](https://sppc.dbkl.gov.my/hubungikami)

日本国土交通省 2025 年行政区面可以区分参考点标注差异和实际错归。

| 被核查的位置 | 官方面内结果 | 离线目录结果 |
| --- | --- | --- |
| GeoNames 标为 Ebina 的参考点（35.38121, 139.39651） | 寒川町 | Samukawa |
| 海老名市内补测点（35.43417, 139.39419） | 海老名市（14215） | Atsugi，确认错归厚木市 |
| GeoNames 标为 Fujimino 的参考点（35.90196, 139.52489） | 川越市 | Kawagoe |
| 富士见野市内补测点（35.86505, 139.51524） | ふじみ野市（11245） | Fujimino |

因此 34 处参考标注差异需逐点复核，其中有参考坐标落在邻市、城区归并和实际城市错配等情形。海老名市内的错归在原有差异坐标之外，仍待修正。[日本国土交通省行政区域数据](https://nlftp.mlit.go.jp/ksj/gml/datalist/KsjTmplt-N03-2025.html) · [海老名市官方资料](https://www.city.ebina.kanagawa.jp/shisei/soshiki/chosha/1016536.html)
