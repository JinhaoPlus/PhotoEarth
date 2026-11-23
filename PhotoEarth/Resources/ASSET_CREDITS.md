# Asset credits

- `BlueMarble.png`: NASA/Goddard Space Flight Center Scientific Visualization Studio, “Blue Marble - A Seamless Image Mosaic of the Earth (WMS),” visualization ID 2915. Blue Marble Next Generation data courtesy of Reto Stockli (NASA/GSFC) and NASA Earth Observatory. Source: <https://svs.gsfc.nasa.gov/2915>
- `SampleIceland.png`: AI-generated fictional demo cover created for Photo Earth. It does not depict a real user or a specific recorded trip.
- The offline world city atlas includes data from Natural Earth 1:10m Populated Places 5.1.2. Natural Earth vector data is public domain. Source: <https://www.naturalearthdata.com/downloads/10m-cultural-vectors/10m-populated-places/>; terms: <https://www.naturalearthdata.com/about/terms-of-use/>.

## Fictional travel demo photographs

The `Demo*.jpg` files are public Unsplash stock photographs selected from the existing local travel-test dataset and copied byte-for-byte on 2026-09-07. They are the previously downloaded 1600-pixel-wide renditions, not full-resolution camera originals. No images were edited or downloaded for this change. The metadata below comes from the saved Unsplash selection manifest.

These photographs illustrate fictional sample journeys. Dates, visit records, favorites, photo counts, and city-center coordinates in `SampleTravelIndex` are synthetic. A city reuses its one photograph for multiple pagination fixtures; these are not distinct captures or a real person’s travel history. Image dimensions reflect the bundled renditions. No private PhotoKit library or device index provides these demo photographs.

| Resource | Demo location | Photographer | Source photograph |
| --- | --- | --- | --- |
| `DemoReykjavik.jpg` | Reykjavik, Iceland | [Rose Breen](https://unsplash.com/@rose_breen) | [Photo gKeeUxw3Vlw](https://unsplash.com/photos/birds-eye-photography-of-city-near-snow-mountain-gKeeUxw3Vlw) |
| `DemoRio.jpg` | Rio de Janeiro, Brazil | [Agustin Diaz Gargiulo](https://unsplash.com/@agustindiazg) | [Photo 7F65HDP0-E0](https://unsplash.com/photos/aerial-photography-of-cityscape-near-sea-7F65HDP0-E0) |
| `DemoSingapore.jpg` | Singapore | [Mike Enerio](https://unsplash.com/@mikeenerio) | [Photo 7ryPpZK1qV8](https://unsplash.com/photos/san-marina-bay-singapore-7ryPpZK1qV8) |
| `DemoTokyo.jpg` | Tokyo, Japan | [Louie Martinez](https://unsplash.com/@thetalkinglens) | [Photo IocJwyqRv3M](https://unsplash.com/photos/tokyo-tower-illuminated-at-dusk-with-city-skyline-IocJwyqRv3M) |
| `DemoSydney.jpg` | Sydney, Australia | [Caleb](https://unsplash.com/@calebrussell) | [Photo JmuyB_LibRo](https://unsplash.com/photos/sydney-opera-house-near-body-of-water-during-daytime-JmuyB_LibRo) |
| `DemoCapeTown.jpg` | Cape Town, South Africa | [Tobias Reich](https://unsplash.com/@electerious) | [Photo -7ZwuyDx2rI](https://unsplash.com/photos/brown-rocky-mountain-beside-sea-during-daytime--7ZwuyDx2rI) |
| `DemoIstanbul.jpg` | Istanbul, Türkiye | [Anna Berdnik](https://unsplash.com/@aberdni) | [Photo 0n0AHB1fgTQ](https://unsplash.com/photos/galata-tower-cityscape-in-istanbul-0n0AHB1fgTQ) |
| `DemoParis.jpg` | Paris, France | [Léonard Cotte](https://unsplash.com/@ettocl) | [Photo R5scocnOOdM](https://unsplash.com/photos/pont-alexandre-iii-bridge-in-paris-R5scocnOOdM) |
| `DemoNewYork.jpg` | New York, United States | [Michael Discenza](https://unsplash.com/@mdisc) | [Photo 5omwAMDxmkU](https://unsplash.com/photos/landscape-photo-of-new-york-empire-state-building-5omwAMDxmkU) |
| `DemoBanff.jpg` | Banff, Canada | [Tevin Trinh](https://unsplash.com/@tevintrinh) | [Photo -QbVBqWlOJg](https://unsplash.com/photos/river-forest-and-mountains-during-day--QbVBqWlOJg) |
开发用的 `Collage1` 至 `Collage7` 依次取自上表 Tokyo、Banff、Rio、Paris、Singapore、Istanbul、Cape Town 的中央竖幅，用于验证放映拼图和转场。

# 构图比例验证素材

`RatioLandscape.png`、`RatioPortrait.png`、`RatioPanorama.png` 由 `Scripts/generate-ratio-fixtures.swift` 绘制，为带完整边框、角标与圆形的程序化测试图，不含照片或私人内容。只通过 Debug 参数 `--demo --photo-ratio-fixture` 使用，分别验证 3:2、2:3 和 3:1 比例。

## Apple TV 主屏地球卡

有可展示旅程时，首卡的卫星地表、星空、地球弧面及左下原生供应商署名均来自 Apple MapKit。只展示地图的 macOS 原生窗口提供完整 16:9 公共首图。公共场景中的六处蓝白光点使用公开城市坐标，不读取用户图库或设备位置。[场景、原图与复现步骤](../../Docs/TOP_SHELF_MAPKIT_ART.md)
