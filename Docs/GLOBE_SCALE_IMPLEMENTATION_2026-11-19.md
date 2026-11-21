# 从卫星地球进入街区地图

首页、独立照片墙与放映仍沿用原先的轨道取景。进入「滚动地球」后，用原有工具条点「放大」，常驻的 MapKit 地图可以连续进入街区。中键圈定当时的可见范围，Back 逐层返回。指定城市的入口继续保留它原来的城市范围。

## 镜头与交接

以原生相机的 `centerCoordinateDistance` 读回值为准。大于 800,000 m 时默认显示卫星与到访亮点，小于或等于该值时默认显示深色普通地图。普通地图关闭交通与 POI。手动选择的底图保留到下一次跨界。最近镜头的产品下限是 100 m，实际可达距离由 MapKit 决定。

`GlobeScalePresentation` 管理尺度、手选底图及标记所有权。近景查询完成前保留原来的亮点。首批就绪时，原生照片图钉接管，包括查询完成且照片为零的情况。移动中沿用上一批原生标注，缩回后取消近景查询。后台、隐藏照片变化和索引替换会清理已保留的照片。每次跨界沿用相机中心、距离、朝向和现有遥控器焦点。[尺度与标记](../PhotoEarth/Domain/Models/GlobeScalePresentation.swift) · [整合到常驻地图](../PhotoEarth/Rendering/Earth/MapKitEarthView.swift)

底图资源慢时，通过单个可取消的系统 `MKMapSnapshotter` 预载目标样式。当前地图在预载期间继续接受输入，预载返回后将配置交给同一张 `MKMapView`。预载图不展示或落盘。实体地图的绘制和重试继续由 MapKit 承担。超过两秒仍在加载时显示影像状态，Reduce Motion 下直接切换。[底图交接](../PhotoEarth/Rendering/Earth/MapStyleHandoff.swift)

## 照片来源与计数

近景与「地图回看」共用冻结视野、SQLite RTree 分批游标、严格屏内投影及原生标注渲染器。每批读取至多 512 条，最多保留 240 个网格单元和 48 条预览记录。屏幕上最多 32 个照片标记。每个标记的坐标来自它的封面资产，聚合角标是成员照片总量。胶片数量与图钉合计来自同一批投影，切到「当前视野」打开照片墙时可与冻结墙总数对账。[视野读取](../PhotoEarth/Features/PhotoViewer/ViewportPhotoBatch.swift) · [原生标注](../PhotoEarth/Rendering/Earth/PhotoPinRenderer.swift)

## 实测记录

tvOS 27.2 的独立 Apple TV 4K 模拟器上，`GlobeScalePresentationTests`、`MapRenderingTests` 与 `MapReviewTests` 的一轮 32 项测试通过。用例包含边界等号、旧请求在缩回后晚到、真实 GPS、空批次、多个国家和日期线的原生投影。1,300 条测试资产跨页读取后，照片墙总数与图钉总数相等，切换城市范围会正确排除其他成员。另有覆盖原生底图预载取消与乱序回调的门禁。[尺度门禁](../PhotoEarthTests/GlobeScalePresentationTests.swift) · [坐标与计数门禁](../PhotoEarthTests/MapReviewTests.swift)

公开示例的遥控器测试从城市卡进入，缩到远景、放到街区、左右移动并缩回。中途切到当前视野，读取到的 1 个图钉包含 9 张，胶片和打开的冻结墙均为 9 张。以下是模拟器采集的同一区域。[卫星](Evidence/2026-11-19/globe/satellite.jpg) · [近景图钉](Evidence/2026-11-19/globe/regional-pins.jpg) · [街区道路](Evidence/2026-11-19/globe/street.jpg) · [完整本机录屏](../.local-test-data/2026-11-19-earth/WarmCameraUI.mov)

冷缓存复核中，GeoServices 曾报告资源超时。冰岛街区道路在一次等待约 40 秒后出现。另一轮缩回时，卫星中心先到，边缘仍有浅灰待绘区域。最终视觉用例检查中部像素与边缘缺块，同时核对实际安装的 MapKit 样式。真实图库、完整运行记录及电视实机验证状态见本次总验收。[遥控器及视觉验收](../PhotoEarthUITests/GlobeScaleUITests.swift)

## 真机短片

已授权的真机验证可在 Debug 启动参数中加入 `--qa-device-record-seconds 140`。允许的时长为 50 至 150 秒。系统确认录制后开始计时，完成后写入应用临时目录 `tmp/PhotoEarthQA/device-screen.mp4`，同目录的 `device-screen-status.txt` 记录授权等待、录制、保存或错误。下一次显式采集替换旧的 QA 文件。使用真实图库地球 UI 用例时，设置 `TEST_RUNNER_PHOTOEARTH_TV_RECORD_SECONDS=140` 即可在批准系统提示后自动走查并等待写入。ReplayKit 在 tvOS 26 与 27 提供该接口，tvOS 的相机与麦克风录制属性不可用。[Debug 真机入口](../PhotoEarth/App/DeviceScreenRecording.swift)
