# 骑将单挑资源

原始素材取自本地《三国志14》CharacterEditor 模型包及此前导出的 `unit-models`。保留原始资源编号，并按原生 KTID 材质关系导入 30 张贴图。

| 资源编号 | 已通过渲染确认的外观 | 骑将演出用途 |
| --- | --- | --- |
| `407a9723` | 披风铠甲角色 | 左方骑将 |
| `8edce9d9` | 重甲角色 | 右方骑将 |
| `cdf4bc12` | 马匹 | 双方坐骑 |
| `26f8ff97` | 长刀外观候选，角色与武器姓名未确认 | 双方骑将持用 |

具体武将姓名与模型编号的对应尚未确认。双方武将名称、头像和武艺来自项目人物数据；演出采用上述两套铠甲角色外观。

`models/*-rig.glb` 保留原始骨骼与蒙皮权重，并剔除不可见布料驱动器的绘制面。坐骑步态、骑乘腿部姿势、握持和交锋手臂动作由 `scripts/war/mounted_duel_actor.gd` 实时驱动，是项目制作的动作。

`manifest.json` 记录原始材质绑定，`texture_sources.json` 记录贴图包与槽位。重建脚本为 `tools/import_duel_cavalry.py` 和 `tools/prepare_duel_rigs.py`。

## 预览与接入

- 游戏 3D 地图中按 **F8**；或双击项目根目录 `预览骑将单挑.cmd`；或在 Godot 打开并运行 `scenes/duel_preview.tscn`。
- 当前预览为金色单挑特效；交锋 8 秒，胜负结算 3 秒，结束后继续战斗。
- 双方坐骑保持面对面，骑将在马前劈砍交锋，不交错换边；交锋时挥出本地长刀模型。
- 单挑最多 30 回合；先被击落者落败，30 回合结束双方都未落马则平手。进度条跟随规则计算的双方体力。
- 演出期间暂停地图的日程画面推进，关闭后继续；不向玩家展示隐藏的敌方单挑。

## 验证

2026-10-05 修订：以马匹和骑手骨骼的脊柱/骨盆高度计算鞍座锚点，坐姿大腿跨过马背、膝盖弯曲，随坐骑同步起伏；正面、侧面、背面渲染保存在 `docs/validation/mounted-duel/seating-*.png`。

`tests/duel_validation.gd` 检查确定性、最多 30 回合、30 回合未击倒判平手及击倒后提前结束。`tests/mounted_duel_validation.gd` 检查真实挑战打开弹层、双方头像、马背鞍点、挥刀、击倒、视口隔离、结果关闭、避免重复播放，以及日志长度不变时的新事件。

`tools/capture_duel_preview.gd` 逐帧渲染真实算法生成的回合，用于生成 `docs/validation/mounted-duel/mounted-duel.mp4`。

`tools/capture_duel_seating.gd` 单独渲染正面、侧面和背面骑乘姿势。验证脚本还检查坐骨高度、大腿水平展开、脚部高度及共用的虚化 shader。

Preview and F8 both use Duel.contest with roster skills and an isolated RNG; they do not force the number of rounds or the winner.

## 动作与握持修订

- 长刀使用原生 UV、`62547770` 颜色贴图和 `99a1887e` 法线贴图；材质提亮暗部，保留纹饰、缠柄和表面细节。
- 握点移至刀柄，采用双骨骼手臂求解，修正手腕轴向并弯曲四指与拇指。
- 上劈、斜劈和反手横斩均包含蓄力、出刀、收刀；防守动作采用较小幅度的格挡。
- 马匹轻微呼吸、摆头和尾部运动，骑手与马鞍同步起伏，躯干随挥刀转动。
- 落马连续经历失衡、离鞍、侧翻、落地，刀随手脱落；动作不改变规则计算的胜负。
- 新录屏采用 24 帧/秒，`grip-detail.png` 与 `weapon-inspect.png` 展示握持与原生贴图近景。

## Current presentation

The active game and default preview use scripts/war/duel_gold_presentation.gd and the original gold map effect in combat_effects_3d.gd. Mounted animation code and assets remain archived in duel_presentation.gd, mounted_duel_actor.gd, mounted_duel_preview.gd and scenes/mounted_duel_preview.tscn. The mounted descriptions above document the archived implementation.

Gold effects last 8 seconds, followed by 3 seconds showing the algorithm winner and loser (or a draw). Army animation and day presentation freeze until the gold controller closes; GameState also waits before starting another simulation day. Existing manual pause and playback speed are preserved.
