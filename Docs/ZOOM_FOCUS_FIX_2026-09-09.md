# 缩放工具条滑动误切按钮修复

用户在 Apple TV 真机确认：工具条显示时，实体左右键能选择按钮，但 touchpad 滑动也会切换「放大／缩小」。这不符合已经确认的交互；滑动应只拖动地球。

## 原因与修复方式

原实现依赖窗口触摸识别器的 `canPrevent` 与同时识别规则，尝试拦截系统识别器。此前测试验证了相机位移与实体按键，却没有向真机输入实际滑动，未证明该方法能阻止 Focus。此次用户反馈确认了这个缺口。

修复采用缩放工具条自身的公开 Focus 环境：

- 工具条由局部 `UIHostingController` 承载，保留原生 SwiftUI 按钮、Liquid Glass、现有布局与可访问标识。
- 工具条内的上下左右方向 Focus 更新被 `shouldUpdateFocus(in:)` 否决。窗口触摸识别器继续接收真实接触与位移，只负责拖动，不再猜测系统识别器的类型或触摸数量。
- 真实 `.leftArrow` / `.rightArrow` 按压通过工具条局部接收器，向原生 `@FocusState` 发出程序化切换请求。中键和 Back 保持原生按钮与返回行为。
- 不设置「按压后若干毫秒放行 Focus」窗口，避免按键释放后的滑动借用旧许可。
- VoiceOver / Switch Control 启用时恢复系统 Focus，停止额外的方向转发与地球触摸拖动，将辅助手势交给系统。

作用范围仅是缩放工具条。首页侧边栏、地点货架、照片墙、详情继续使用已有系统导航。进入和退出工具条不重建地图、不暂停触摸生命周期，已确认的拖动仍按最多 30 Hz 合并提交相机。

Apple 公开说明任何祖先 Focus 环境均可否决更新；`UIFocusUpdateContext` 只有方向与前后元素，没有触摸或按键来源，所以不能据此猜测来源。[Apple Focus 指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/WorkingwiththeAppleTVRemote.html)、[Apple 输入指南](https://developer.apple.com/library/archive/documentation/General/Conceptual/AppleTV_PG/DetectingButtonPressesandGestures.html)。当前 tvOS SDK 接口亦已核对。

## 验证与交付

证据根目录为 `.local-test-data/zoom-focus/validation/`。

| 验证项 | 结果与证据 |
| --- | --- |
| Focus、触摸生命周期与工具条持续拖动模型 | `Verified.xcresult`：25 项单元测试通过，参数化后 30 次执行；含四向 Focus 否决、按压后无放行窗口、原生 Focus 祖先与真实按钮切换、RTL、辅助导航旁路、场景禁用、轻触与按压所有权 |
| 缩放工具条真实按钮 UI | `FocusRuntime.xcresult` 中 2 条 UI 流程通过：长按打开、左右选择、实际相机缩放与边界、Back／完成关闭、重新打开和恢复地球 Focus |
| 既有导航 | `Verified.xcresult` 中 4 条 UI 流程通过：四层返回、地点卡进入返回、货架继续向下、侧边栏国家／城市与照片墙返回；该结果包共 29 项测试、34 次执行，零失败 |
| Liquid Glass 与署名 | 已复核 `screenshots/1BE9FDC3-203B-467C-A212-20A224E1C576.png`：原生玻璃、单层按钮 Focus、拖动提示、地球全屏与底部法务净空保持 |
| Release 与设备签名构建 | `ReleaseBuild.xcresult` / `DeviceBuild.xcresult` 通过；构建前后生产源码与资源哈希一致，严格 codesign 验证通过，临时 App-only scheme 已删除，正式签名配置未改 |
| 客厅 Apple TV 安装与启动 | 2026-09-09 22:48 前已成功安装并按正常模式前台启动（无 `--demo` 参数），PID 12817；`device-install.json` / `device-launch.json` 均为 success。未执行图库重建、缓存删除或示例数据替换 |

交付执行文件 SHA256：`369f0dbbe81d6efdaf0d8b50c52742bf651de8ad947523c0169924f80e073f82`。`git diff --check` 通过。该版本包含本轮 Focus 修复与此前侧边栏修改。

首次实际托管 Focus 测试错误地假定 SwiftUI 的底层 `UIFocusItem` 暴露按钮 AX identifier，得到 nil；同一运行中的两条按钮 UI 已通过。测试改为验证真实 Focus item 在宿主内稳定约 100 ms、左移换到另一 item、右移回到原 item；具体按钮身份继续由 UI 测试断言，未弱化为只验证状态变量。原始 `FocusRuntime` 单元失败与最终 `Verified` 通过均保留。

tvOS `XCUIRemote` 不提供真实 clickpad 滑动注入。Simulator 的虚拟遥控器支持按住 Option 并移动鼠标模拟触摸，但当前 UI 自动化接口不能独立保持修饰键并移动鼠标，本轮未取得真实间接触摸端到端证据。回调边界测试与按键 UI 测试必须区分，不能继续把后者通过写成实际滑动已验证。最终仍须在实体遥控器上确认：工具条打开时左右滑动仅移动地球；物理左右键仅切按钮；按压后旧接触不恢复拖动；重新落指后正常拖动。
