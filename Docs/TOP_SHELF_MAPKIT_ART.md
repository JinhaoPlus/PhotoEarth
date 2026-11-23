# Apple TV 主屏的公共地球原图

主屏有可展示旅程时，「滚动地球」首卡可使用原生 MapKit 俯瞰东亚的公共卫星画面。没有可读旅程海报时，扩展收起整排。北京、成都、香港、台北、首尔及东京的公开位置由 MapKit 放置六个蓝白光点。生成器不申请定位或图库授权。公共画面里的城市选择固定，用户开启主屏旅程后的私人画面由应用单独发布。[无损原图](../Design/TopShelf/MapKit/PublicOrbit.png) · [相机、时间、坐标及像素检查](../Design/TopShelf/MapKit/PublicOrbit.json)

## 画面来源

在 Mac 上创建只含 `MKMapView` 的独立窗口，使用和 tvOS 首页相同的 `MKImageryMapConfiguration(elevationStyle: .realistic)`。星空、地球轮廓、光照、卫星图及左下署名均来自同一原生画面。已核对当前区域 MapKit 提供的「高德地图」署名。截图只抓本进程的地图窗口，不含桌面及其他应用。[生成工具](../Scripts/generate_public_mapkit_shelf.swift) · [首页卫星配置](../PhotoEarth/Rendering/Earth/PhotoMapStyle.swift)

16:9 公共首卡使用北纬 29°、东经 116°、正北朝上、实际俯仰角 35° 的相机。此次 macOS 的原生地图在首页使用的 10,000 km 距离会把俯仰角压到 0°，调至 6,000 km 后可稳定保持 35°。原始 16:9 画面完整保留地平线与底部署名。六个光点使用与首页相同的渐变色和衰减位置，交给原生 `MKAnnotationView` 定位。

## 复验

在仓库根目录运行 `sh Scripts/generate_top_shelf_globe.sh`。Mac 需要可用的 MapKit 影像和截取本进程窗口的权限，并已安装 Xcode 命令行工具和 libjpeg-turbo。生成过程创建一个地图窗口，采集完毕后关闭。地球光照与在线地图影像会随时间变化，采集时间与原图 SHA-256 写入每张原图的 JSON 记录。[打包脚本](../Scripts/generate_top_shelf_globe.sh)

可用 `xcrun swift Scripts/verify_public_mapkit_shelf.swift` 独立复验现有文件。验证单次采集先截图，再隐藏原生图钉，在同一镜头重拍。逐个对比六枚图钉实际屏幕中心附近的像素，记录亮度变化。在倾斜地球边缘，macOS 的 `convert(coordinate:)` 与系统真实摆放的图钉有偏差，回执同时记录这项差异。扩展资源和用于系统传输的两张 JPEG 都会与对应原图比较整幅地表和单独的左下署名区域，并校验尺寸、个人 GPS 元数据及首卡传输字节预算。[复验工具](../Scripts/verify_public_mapkit_shelf.swift) · [16:9 原图回执](../Design/TopShelf/MapKit/PublicOrbit.json)

主 App 的品牌目录注册应用图标、商店图标和 App Store Connect 要求的宽幅货架图。运行 `sh Scripts/verify_tv_home_brand.sh` 实际编译 tvOS 资源，并检查 `Assets.car` 与产物 Info.plist 中的注册项。两张 1600 × 900 地球图片均在动态扩展中，主 App 的宽幅静态图仅呈现纯黑背景。[品牌资源门禁](../Scripts/verify_tv_home_brand.sh)
