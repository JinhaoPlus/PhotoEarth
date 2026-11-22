# 遥控器返回与焦点验收

环境为 Apple TV 4K 第三代模拟器，tvOS 27.2。使用 XCTest 注入遥控器按键事件，素材为公开示例图库和独立模拟器中的合成 PhotoKit 相册。页面文案与按钮通过辅助功能树和截图核对。

| 场景 | 验收内容 |
| --- | --- |
| 首页、最近到访、国家列表 | 从深处按 Back，内容和焦点回页首。第二次 Back 进入原生侧边栏。从探索或照片墙退回时恢复来源卡片。 |
| 单个国家 | 保留国家标题、统计及「查看所有照片」。深处 Back 先聚焦页首动作，再退回原国家卡片。 |
| 照片墙 | 页头保留放映和集合墙的地图回看。深处 Back 回第一张，页首 Back 退回来源。当前画面墙用 Back 恢复同一张地图。空墙可退出。 |
| 地图和缩放 | Play/Pause 打开缩放工具条。Back 收起工具并把焦点交回地图，下一次 Back 才退出当前地图。 |
| 照片详情 | Back 先一起收起操作层与照片信息，再回墙上最后浏览的照片。跨页后焦点仍指向最后实际观看的照片。 |
| 从照片探索地球 | 以照片真实 GPS 取景。Back 回原照片，再回来源墙。来源墙保留原生投影、分页与选择，访问或相册权限变化继续使已失效内容退出。 |
| Top Shelf 地球链接 | 一次 Back 回 App 首页的原生侧边栏。向右进入首页，示例城市卡片仍可浏览。 |
| 放映和配乐 | 配乐弹窗、放映工具和放映画面逐层退回。取消选曲恢复曲目、播放或暂停状态和入口焦点。重试、关闭本场配乐及重新播放仍可操作。 |
| 设置和扫描 | Back 放弃设置草稿。首次选范围可回欢迎页或示例旅程的连接入口。显式确认才保存或开始扫描。退出扫描进度回来源，暂停继续保留独立操作。 |

## 测试结果

共 34 条 UI 用例和 22 条单元用例通过。回归用例跨过第 48 张照片，确认页首与焦点一起复位，再按 Back 回到同一张地图。扫描范围在合成 PhotoKit 相册上实际保存，重叠相册验证了排除范围。

[各用例最终结果](../.local-test-data/navigation-20261121/test-results.json)

照片墙查询失败的重试条件和触发路径通过代码核对，实际 UI 用例覆盖空墙返回。配乐离线重试和在线串流由模拟器实测，Apple Music 使用测试驱动。Top Shelf 通过 URL 注入验证 App 内路由。实体遥控器、电视主屏货架和真实 Apple Music 账户播放尚待真机验证。

## 截图

- [国家页](../.local-test-data/navigation-20261121/screenshots/country.png)
- [最近到访 Back 后的页首](../.local-test-data/navigation-20261121/screenshots/recent-top.png)
- [当前画面照片墙](../.local-test-data/navigation-20261121/screenshots/current-view-wall.png)
- [照片信息与小地球](../.local-test-data/navigation-20261121/screenshots/photo-information.png)
- [缩放工具条](../.local-test-data/navigation-20261121/screenshots/zoom-controls.png)
- [Top Shelf 链接返回首页](../.local-test-data/navigation-20261121/screenshots/public-link-home.png)
- [已选配乐](../.local-test-data/navigation-20261121/screenshots/soundtrack.png)
- [权限拒绝页面](../.local-test-data/navigation-20261121/screenshots/photos-access-denied.png)
