# 洛阳场景接入状态

依据已核对城市对应表，洛阳属于中原场景 102（city001_chugen）。

当前包含 47 个原始模型、293 条摆放记录，以及由 Godot 渲染的独立城内背景。洛阳六处建筑操作沿用现有城市系统，并独立设置入口坐标。

城内背景现使用 `preview-perspective.png`：透视镜头，俯角 24 度、水平偏转 9 度、视场角 44 度，宫城位于画面后方中央，前景街区延伸出画面。入口坐标对应此镜头。旧版 `preview.png` 保留供对照。渲染预览可使用 `--rendering-method gl_compatibility --script res://tests/capture_luoyang.gd`；附加 `-- --angles` 输出角度对比。

## 尚未还原的部分

已恢复 118 个材质的原始色彩图绑定：读取 G1MG 中各材质的颜色采样槽，再通过原始 CSV 绑定表与春季纹理节点解析具体贴图，结果记录在 `material-bindings.json`。不再按建筑类别猜测贴图，也不混用四季纹理节点。府衙前广场、道路、屋顶、城墙及植被使用各自对应贴图。背景以 2560×1440 渲染，用于城内界面缩放显示。

法线、原版专用地形混合着色、灯光后处理，以及 NPC、旗帜和植被动画仍未接入。当前成果不是原版 1:1 成品。

`scene.json` 保留模型及摆放信息；`tools/import_luoyang_scene.py` 负责整理源数据；`scripts/luoyang_scene.gd` 负责渲染；`tests/capture_luoyang.gd` 可重新生成背景及带菜单的预览图。
