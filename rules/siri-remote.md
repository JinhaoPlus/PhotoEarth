# Siri Remote、工具条与 Focus

## 直接操控与输入所有权

- Siri Remote 实体上下左右单击只产生一个小步；持有约 180 ms 后才持续转动并平滑加速，松开立即停止，不追加惯性或补步。

- 地球全屏场景使用直接操控输入，不使用地点卡片 Focus 路由；底部记忆照片带默认不可聚焦。
- 俯瞰首页和照片墙属于明确的选择界面，使用标准 tvOS Focus System；进入直接操控地球后才把焦点交给全屏透明输入面。
- 通过 Game Controller 的 `GCDirectionalGamepad` / `GCMicroGamepad` 接收实体 Siri Remote 的方向与中键按压；拖动统一从 UIKit `.indirect` 触摸事件接收。
- 绝对坐标不是可靠接触边界的证明。UIKit `.indirect` 的 began/moved/ended/cancelled 是唯一拖动来源，Game Controller 只处理实体按键，不能因其缺少独立触摸接口便关闭拖动，也不能双路提交同一次位移。不能仅凭旧 `GCControllerButtonInput.isTouched`、方向按钮存在或无活动超时推断轻触生命周期。
- 不再按内圈／外圈分配不同手势。落指意图门槛与已确认拖动的灵敏度分开，起动后完整累积位移，松手不回放；实体方向或中键按压拥有整次接触，按键释放后不得接回旧拖动，必须可靠抬手并重新落指。
- 第二代及更新 Siri Remote 要区分主触摸面与 `GCInputDirectionalCardinalDpad` 外圈物理方向键：全触摸面的 UIKit 滑动是“抓住地球”的直接拖动，视觉地表必须与手指同向，松手后不追加惯性、反向回弹或焦点方向补偿；物理方向键保持镜头方向语义。两者不得共用同一方向符号。
- 模拟器和没有触摸面的遥控器保留方向按压；有 touchpad 的设备必须保留全触面拖动，不能仅因 Game Controller 能力检测不足退化为按键。点按 Play/Pause 打开同一原生 Liquid Glass 缩放工具条，工具条内也能继续拖动；落指、慢拖、快扫、抬手重落与设备输入能力必须在 Apple TV 真机复验。
- Back/Menu 在缩放工具条内先关闭工具条并恢复地球的按键操控；地球分支从照片详情逐级退回照片墙、滚动地球和俯瞰首页。顶层页面由系统管理侧边栏展开与退出，不能在内容页直接拦截为退出应用。
- 拖动与方向按压松开后均无惯性；相机飞行、缩放和 Focus 动效遵守 Reduce Motion。Reduce Transparency 下缩放 Dock 使用可读深色实底。
- 不实现电视屏幕上的微型鼠标指针。

- 独立 UIKit 触摸桥在探索场景中持续安装，打开或关闭工具条不移除它。工具条内不创建透明可聚焦地球输入面；触摸通路不依赖地球拥有 Focus，也不能让拖动同时移动按钮 Focus。工具条只屏蔽地球方向转动与 Select 导航，让实体按键操作原生按钮；退出动画完成后恢复地球按键操控和唯一输入面 Focus。

- 照片墙和详情仍完整暂停地球输入。工具条持续拖动不得扩展到照片墙、详情或俯瞰首页。

- 轻触、搁置与落指微抖保留当前相机和照片带。UIKit began 和首次 moved 用于建立落点，最初位移不回放。意图门槛 12 pt，未确认单步跳变门槛 120 pt。确认后按窗口短边的一半归一化，已确认位移完整累积并按帧提交。
- 缩放工具条使用独立的公开 `UIHostingController` Focus 环境。仅实体方向输入切按钮，触摸拖动地球，中键与返回保留原生行为。VoiceOver 或 Switch Control 启用时恢复系统导航并暂停额外拖动。[缩放 Focus 修复](../Docs/ZOOM_FOCUS_FIX_2026-09-09.md)

## 按键由当前场景处理

- 直接操控时，中键松开冻结当前镜头并打开照片墙。Play/Pause 打开原生 Liquid Glass 缩放工具条。工具条含缩小、放大及相关底图／范围控件，保留 MapKit 署名净空。触摸拖动继续有效，实体方向切换 Focus，中键执行当前按钮。
- 照片墙的 Play/Pause 启动放映，详情的 Play/Pause 播放或暂停动态内容，放映中的 Play/Pause 暂停或继续整场。
- 离开当前详情、切换资产或回后台时停止并取消不再有效的媒体请求。

## 屏幕提示

- 探索页顶部的可见操作提示使用严格对齐的 2 × 2 网格，四格均为「按键／手势图标 + 一个动作／对象词」：拖动、转动、照片、缩放。缩放格以当前控制器提供的 Play/Pause 符号表示实体按键（缺失时回退 `playpause.fill`），文字只写「缩放」，不再显示「播放／暂停键」或「缩放控制」等句式。完整操作句只用于 VoiceOver，各提示保留稳定 accessibility identifier。
- 四格图标优先读取当前 Game Controller 实体输入元素的 `sfSymbolsName`，并监听当前控制器、连接状态与用户按键映射变化；触摸面、物理方向环、中键和 Play/Pause 分别对应 `GCInputDirectionalDpad`、`GCInputDirectionalCardinalDpad`、`GCInputDirectionalCenterButton` 与 `GCInputMicroGamepadButtonX`。系统未提供、返回无效符号，或模拟器／通用手柄把中键与 Play/Pause 错画成 A／X 字母键时，回退到语义明确的公开 SF Symbols；不得复制 Xcode Simulator 的私有遥控器 PDF 资源，也不引入第三方图标包。
- 记忆地平线不再重复显示「按中键查看照片」；有内容时只保留照片带标题，无预览或查询失败时只显示简短状态。中键打开照片墙的完整说明仍由直接操控地球的 VoiceOver 标签提供。

输入模型与回归见 [交互行动计划](../Docs/INTERACTION_ACTION_PLAN_2026-09-08.md)。
