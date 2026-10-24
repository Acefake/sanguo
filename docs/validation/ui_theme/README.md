# 统一主题移植（feat/ui-theme → 新 main）验证记录

分支 `feat/ui-theme-port`，基于 main 8d25fc2。截图在 Linux arm64 沙箱（Xvfb + llvmpipe）用 `tools/capture/capture_ui_screens.gd`、`tools/capture/capture_character_system.gd` 拍摄；大图转成 JPEG 以控制仓库体积（本目录有 `.gdignore`，Godot 不导入）。

| 文件 | 内容 |
|---|---|
| `campaign_1600x900.jpg` | 战役地图：新外壳顶栏、小地图、浮条，glass 面板 |
| `picker_1600x900.jpg` | 选择战场：卡片网格 + 战场缩略图，浅色 glass |
| `settings_1280x720.png` | 设置页（glass 调色板，面板不透明度 0.98） |
| `talents_1600x900.jpg` | 人才页（右侧抽屉）：寻访、在野人才、人物履历 |

## 结论

- **非 UI 部分逐字节一致**：整套 133 项（战斗套件 + 新 main 附加测试 + 战役 183 行逐日哈希）与 main 树（8d25fc2）对比，132 项日志相同、全部通过/失败状态相同；唯一差异是 `step_latency_validation` 的计时行（每次运行都会变）。
- **UI 测试**（headless 跑逻辑，Xvfb 跑 GL）：

  | 测试 | main 8d25fc2 | 本分支 |
  |---|---|---|
  | dispatch_view_validation | 0 | 0（headless 与 GL） |
  | officer_page_validation | 0 | 0（headless 与 GL） |
  | battle_start_validation | 0（headless） | 0（headless）；GL 下 133 |
  | check_world_hud | 第 18 行断言失败（抽屉未显示，预存） | WORLD_HUD_CHECK_OK（headless 与 GL；检查工具随新外壳更新） |
  | 人才页 harness | 通过 | 通过；各状态的界面文字集合与 main 相同，只是按钮排在内容之后（新布局），且「·」分隔换成留白 |
  | war_ui_render / battle_extension_ui | headless 不出帧（需 frame_post_draw） | 同左；GL 下 133 |

- **code=133 是沙箱环境问题**：arm64 下贴图被导入为 ETC2，llvmpipe 不支持 ETC2，建好 3D 世界的分层植被贴图（texture_layers=19）后引擎 C++ 崩溃（signal 4, cowdata index）；main 上同样崩。**需要在 Windows 上复核** `war_ui_render_validation`、`battle_extension_ui_validation` 和 HUD 模式截图（`capture_ui_screens.gd --only=hud`）。
- 修复：`world_map_hud.gd` 原来 preload 已删除的 `rtk14_world_3d/state.gd` 取 `WORLD_SIZE`，导致 3D 地图脚本编译失败；改为读 `map.WORLD_SIZE`。分支改动的 24 个 `.gd` 全部可编译。
- 看图修正：设置页面板 0.94 透明时底下文字透出 → 0.98 + glass 遮罩；战役地图城名牌透进抽屉/顶栏 → glass 面板不透明度 0.84→0.94。
