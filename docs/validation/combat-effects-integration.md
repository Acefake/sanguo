# 交战光效接入

来源目录：C:/Users/10228/.codex/visualizations/2026/10/04/01a104a0-d367-7881-a636-f066ae161007/三国志14_动画与战斗资源/纹理预览/RRPreview。

选择并实际接入三个 RGBA 纹理：d1e25cec_000（白色扫击）、035f1bcf_000（命中星芒）、bfbff8cd_000（烟尘）。源文件映射保存在 assets/armies/rtk14/effects/sources.json。原 EFPL/G1E 播放参数和纹理绑定未验证；当前使用原纹理与 Godot 原生播放逻辑，不声称复现原游戏发射器。

army_world_3d 根据本日 combat_tick、可见攻击目标及本日强攻参与列表驱动 combat_effects_3d。近战光效放在接触点，攻城朝城市格定位；远射使用投射移动。军队朝攻击目标转向，并保留已有士兵攻击姿态播放。特效按地形高度摆放，接受时间倍率，暂停时冻结，日播放结束清理。不基于过期敌情显示当前特效。节点每帧复用，上限 24 个联系点。

验证：combat_effects_validation 通过接触目标、城市目标、远射、过期敌情、非交战、地形高度、节点复用、数量上限和停止清理。xiaopei_battle_validation --capture 在实际 Vulkan 3D 场景通过真实交战产生特效、暂停冻结、日结束清理；截图 army-assets/xiaopei-combat-effects.png。此次没有改变伤亡、决策或攻城规则，未修改正式存档。
