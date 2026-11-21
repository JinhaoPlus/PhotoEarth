---
name: verify-photoearth
description: 验证 PhotoEarth 的 tvOS 发布候选。用项目的 Release 构建、Apple TV 模拟器与遥控器 UI 测试检查归档条件，或按功能地图复验用户入口。
---

## 环境检查（Doctor）

从包含 PhotoEarth.xcodeproj 的目录执行。使用选定 Xcode 的开发工具、Python 3.9 或更新版本，以及兼容工程部署目标的 tvOS Simulator runtime。

```sh
Scripts/release_gate.py doctor
```

核对打印的 Release 版本、构建号、bundle ID、Xcode 构建号及模拟器型号。实际运行会创建一台空白模拟器，避免碰触已有图库与其他验收会话。同一工作区一次只运行一道门禁。

## 启动与操作（Launch / Drive）

```sh
Scripts/release_gate.py
```

先为通用 Apple TV 编译 Release 主程序与 Top Shelf 扩展，再在全新的 1080p Apple TV 模拟器上用 Debug fixture 和 XCTest 驱动真实界面。XCTest 负责启动应用、等待可交互控件并发送遥控器按键。例如欢迎页先等到 `welcome-connect`，按 ↓ 和中键选择示例，随后检查 `overview-explore-button` 获得焦点及示例标识可见。放映用例从最近到访进入墙，开始、暂停、选择素材，再按 Back 核对原来的墙和焦点。

发布必跑选择在 Scripts/release_gate.py 中。它执行整个模拟器单元测试目标，显式排除两个私有图库探针，另逐项选择遥控器用户路径。查对应入口、fixture、成员范围、预期画面和专项用例，见[功能地图](features/README.md)。涉及真实 Photos、实体遥控器或系统主屏时，按功能页补充对应证据，遵守 AGENTS.md 的真机安装授权。

## 证据与归档（Evidence）

命令输出每轮证据目录 `.local-test-data/release-gate/<本轮目录>/`。看 `report.json` 的状态、版本、内容指纹与测试数，打开 `Tests.xcresult` → Tests 查看点击、断言、截图和失败行。构建和测试的原始输出分别在 `release-build.log`、`test.log`，测试摘要在 `tests.json`。若构建或启动提前失败，先查当步日志。单独复验一个失败用例时保留原失败记录，修复后重新跑完整入口。

退出码为 0 且门禁报告通过后，可按原方式使用 Xcode 的 Product → Archive 或 xcodebuild archive。归档会核对工作区的通过记录、构建设置、源码及测试输入。版本、构建号、工程、资源、用例或门禁变化后重新运行。自动门禁只涉及本机构建与测试。签名、按改动需要的真机验收、TestFlight 和商店发布按各自证据记录。

## 清理（Cleanup）

正常结束、Xcode 返回失败及前台 Ctrl-C 时，脚本清理本轮的模拟器及临时 DerivedData，保留证据目录。若进程被强行终止，可从本轮 `report.json` 读取 `simulator`，从日志读取 `-derivedDataPath`，核对后只清理本轮资源。归档需要通过记录及其引用的结果包。

## 维护

新增用户入口、改变照片范围或焦点恢复时，同步更新 Docs/FeatureMap 对应页与 XCTest。跨版本需保持的关键路径加入门禁，使用 pstack 的 `maintain-verification-skill` 复核功能地图与实际入口是否一致。
