# 国家与地区名称核验（2026-11-21）

对 249 个 ISO 3166-1 二字码和 CLDR 收录的 XK，分别传入 en、ja、de、fr、es、it、zh-Hans、zh-Hant、zh-Hant-HK、zh-Hant-MO、zh-Hant-TW。tvOS 27.2 模拟器与 macOS 27.0.1 实际执行 Foundation 的 `Locale.localizedString(forRegionCode:)`，两个系统的 2,750 个返回值逐字一致，全部非空。此处检验名称，坐标覆盖另行统计。随包 atlas 的区域边界包含这 250 个代码中的 249 个，缺 UM（美国本土外小岛屿）。[ISO 代码底表](https://github.com/pycountry/pycountry/blob/main/src/pycountry/databases/iso3166-1.json) · [Unicode 的 XK 收录说明](https://cldr.unicode.org/index/downloads/cldr-24-release-note)

## 与 Unicode CLDR 49 的差异

逐项比较 Unicode 的完整语言包 `cldr-localenames-full@49.0.0` 中的 territory 默认名。在该包中，台湾繁体中文默认值来自 zh-Hant；港、澳各用各自地区文件。2,690 项逐字相同。剩余 60 项逐条记录 Foundation、CLDR、命中的替代名和产品采用的写法。31 项命中 CLDR 的另一种正式形式（24 项 short，6 项 chagos，1 项 variant），29 项没有逐字命中当前语言的替代名。[完整差异](REGION_NAME_DIFFERENCES_2026-11-21.csv) · [Unicode 语言包](https://github.com/unicode-org/cldr-json/tree/49.0.0/cldr-json/cldr-localenames-full/main) · [CLDR 地区显示名原则](https://cldr.unicode.org/translation/displaynames/countryregion-territory-names)

在两个产品使用相同的两条针对 CLDR 差异的显示修订。意大利语 CI 原本是法语国名，改用意大利外交部旅行页面与 CLDR 共用的意大利语写法 **Costa d’Avorio**。英语 GS 从系统截略的 **So. Georgia & So. Sandwich Isl.** 展开为 **South Georgia & South Sandwich Islands**。其余差异保留 Apple 写法，包括 CN 的大陆表述、港澳短名、IO 的查戈斯群岛用名、日语全角括号和地区间通行的拼写形式。CSV 中的 “different” 只表示逐字不同。[意大利外交部旅行页面](https://www.viaggiaresicuri.it/find-country/country/CIV) · [CLDR 英语表](https://www.unicode.org/cldr/charts/49/summary/en.html)

## NR 的现行名称

2026 年 6 月 26 日，该国向联合国通报更名。Foundation 与 CLDR 49 对 NR 的写法一致，其中五种欧洲语言与台湾惯用繁体还保留旧名。差异表追加 7 行，保留旧值与产品实际显示列。所有设置沿用区域码 NR。

- 英、法、西语用 **Naoero**。德语和意大利语也采用 **Naoero**，德国外交部国名表列为短名，意大利外交部的使领馆国家目录亦使用该名。[联合国三语记录](https://metadata.un.org/skosmos/unms/en/page/520?clang=es) · [本国政府](https://www.nauru.gov.nr/) · [德国外交部国名表](https://www.auswaertiges-amt.de/resource/blob/215256/329771379c1c045ecd02eed3e3667df0/laenderverzeichnis-data.pdf) · [意大利外交部国家目录](https://www.esteri.it/it/ministero/struttura/laretediplomatica/?c=&capomissione=&pag=12)
- 台湾领事事务局在入境说明使用短名 **諾埃羅**。台湾繁体采用该名，无地区的繁体沿用项目的台湾繁体用词。[台湾领事事务局](https://www.boca.gov.tw/sp-foof-countrycp-02-28-3e2b6-02-1.html)
- 简体仍用 **瑙鲁**，港澳繁体仍用 **瑙魯**，日语仍用 **ナウル**。这三种写法均可在改名后的本地官方材料查到。[中国外交部](https://www.fmprc.gov.cn/web/gjhdq_676201/gj_676203/dyz_681240/1206_681592/) · [香港邮政](https://www.info.gov.hk/gia/general/202610/13/P2026101300397p.htm) · [澳门旅游局](https://www.dst.gov.mo/zh-hant/tourism-crisis-management/tourism-crisis-management-travel-alert.html) · [日本外务省](https://www.mofa.go.jp/mofaj/press/release/pressit_000001_04484.html)

## 历史底表没有 ISO 码的 12 条记录

Natural Earth 底表中，7 个索马里兰地点、2 个北塞浦路斯地点、3 个科索沃地点缺少二字区域码。以各城市原始代表点调用实际匹配器，在 11 个 Locale 中分别回放仅 TSV 与 TSV 加 atlas 两条路径，共 264 个结果。修复前两个路径都把前 9 城的地区显示成英语；3 个科索沃地点在使用 atlas 时已正确使用 XK，单用 TSV 时使用英语。修复后的 264 个结果都有稳定地区标识及其对应的本地化标题，各路径原有城市身份保持一致。区域键只写入显示标签，不更改空间匹配半径、归属规则或原始坐标。[Natural Earth 地区数据及原始字段](https://github.com/nvkelso/natural-earth-vector/blob/master/geojson/ne_10m_admin_0_countries.geojson)

| 来源表地区 | 显示所用标识 | en / de / es / fr / it | ja | 简体 | 繁体 / 台湾 | 香港 / 澳门繁体 |
| --- | --- | --- | --- | --- | --- | --- |
| Somaliland | NE:SOL | Somaliland / Somaliland / Somalilandia / Somaliland / Somaliland | ソマリランド | 索马里兰 | 索馬利蘭 | 索馬里蘭 |
| Northern Cyprus | NE:CYN | Northern Cyprus / Nordzypern / Chipre del Norte / Chypre du Nord / Cipro del Nord | 北キプロス | 北塞浦路斯 | 北賽普勒斯 | 北塞浦路斯 |
| Kosovo | XK | 由 Foundation 提供 | コソボ | 科索沃 | 科索沃 | 科索沃 |

NE:SOL 和 NE:CYN 取自 Natural Earth 的 ADM0_A3 并加来源前缀。按原表地区语义展示，两者沿用旧版国家集合的路线键。Top Shelf 遇到旧快照中的英文地区，可以按当前语言重建同名城市的副标题。LensPin 使用相同地区名解析器，国旗绘制沿用仅接受两位区域码的限制。

北塞浦路斯使用原表的地理短名。德文、西文和日文分别对照了德国外交部、欧洲议会和日本外务省用例；法文与意大利文使用 Natural Earth 短名。[德国外交部](https://www.auswaertiges-amt.de/de/newsroom/100419-nordzypern-223830) · [欧洲议会](https://www.europarl.europa.eu/doceo/document/E-5-2001-3185_ES.pdf) · [日本外务省](https://www.anzen.mofa.go.jp/info/pcsafetymeasure_193.html)

繁体地区用词分别核对台湾领事事务局的「索馬利蘭」「北賽普勒斯」、香港电台和澳门日报的「索馬里蘭」，以及港澳政府清单中的「塞浦路斯」。台湾与港澳使用不同的惯用地名。[台湾领事事务局（索馬利蘭）](https://www.boca.gov.tw/sp-trwa-content-2905-dd844-1.html) · [台湾领事事务局（賽普勒斯）](https://www.boca.gov.tw/sp-foof-countrycp-01-252-ea841-04-1.html) · [香港电台](https://news.rthk.hk/rthk/ch/component/k2/1839433-20260111.htm) · [澳门日报](https://www.macaodaily.com/html/2026-01/02/content_1880847.htm) · [香港政府](https://www.1823.gov.hk/tc/faq/which-countries-or-places-accept-the-international-driving-permit-issued-in-hong-kong-in-alphabetical-order) · [澳门交通事务局](https://www.dsat.gov.mo/dsat/subpage.aspx?a_id=1614764283)

验证记录：tvOS 27.2 模拟器的地区名称、国家集合、地名解析三个测试套件共 29 项通过（含 NR 更名与 11 种语言和地区设置）；两端 Swift 匹配器以 1,258 个公开坐标和 8 种语言完成了 10,064 次比对，城市身份、地区标识和标签全部一致。LensPin 的 iOS 模拟器和原生 macOS Debug 工程均已构建成功。

差异表所引 Unicode 数据 © 2001–2026 Unicode, Inc.，适用 [Unicode 数据许可](https://www.unicode.org/license.txt)。
