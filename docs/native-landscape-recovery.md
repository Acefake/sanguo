# 原版全地图数据恢复

本次修改覆盖全图，仍未达到 1:1。游戏来源目录只读；当前实现及证据均保存在 Godot 项目与资源提取目录。

## 原始地形和摆放

`heightmap.r32`、`world_preview_height.r32` 均保留原始 2049² 厘米高度。取消生成河床、87 处额外村落地台和全图高度调整；`world_layout.json` 额外村落清单为空。运行时城市与关口仍处理局部地基，关口仅在窄墙体占地及 3 米肩部填补空隙，不降低来源地面。

地形网格由两米抽样改为来源一米采样，保留窄山脊。64 个地形块仍生成网格 LOD，并缓存到 `terrain/mesh-cache/`；缓存键包含最终高度数组的 SHA-256、网格版本与采样步长，城池或关口地基发生变化时不会沿用旧网格。后续启动直接加载压缩缓存，避免每次重建网格与 LOD。

原场景 `6dbf662e` 的 1120 条静态位置、四元数和缩放全部保留。当前场景配置 `6eff205a` 位于 `KIDSSystemResource_b041e18a.kidsobjdb`，它同时引用已恢复的地表、植被和静态场景数据库；其可见清单 `63f9f0ba` 只列出 105 处原始村落，与来源村落实例集合完全一致。当前按这份清单绘制；其余 1015 条制作摆放保留为资产与来源记录，不再叠加绘制到已烘焙高度图之上。游戏代码可能对清单另作修改，尚未确认。清单和来源 SHA 见 `stage_visibility.json`。静态物件直接使用来源 Y，不再跟随派生地面补偿高度。

## 地表材质

从 `KIDSSystemResource_f029fe04.kidsobjdb` 的 `5f441cb4` 恢复调色板 `b1f11a12`、数组 `3bc87718` 和元素 `d9bdaba2`。全图 G1T 为 `239167e0`，19 层数组为 `57ee6cea`。18 个控制索引的数组切片及米制纹理周期为：

```text
slice: 12,16,15,10,9,11,8,17,13,14,18,0,4,3,2,5,6,7
period:60,40,40,80,60,30,20,50,50,10,50,60,40,60,15,50,40,60
```

控制图保留原始 BGRA8 字节；着色器读取 `.bgr` 为主材质、次材质和混合权重，次材质 255 表示无次材质。接入三套来源数组和三张全图纹理：颜色/遮蔽、法线/高度、反射率/粗糙度。保留 BC3 来源 mip 链，尾部补齐 Godot 的 2×2 与 1×1 级别。

来源地形 DXBC 是 `dc52fd1c` / `PB2LS-Gbi`。移植四点插值、法线 alpha 高度锐化混合和坡面投影；取消颜色猜测映射、固定灰岩覆盖及额外噪声。原版副切线是 `cross(tangent, normal)`，已修正先前相反的叉积顺序。

原配置 BilinearRate=0.5，NearFarBlendingOffset=600 米、Range=150 米、LODDistanceScale=5。坡面阈值和近远区间的运行时绑定尚需核实。Godot 标量 SPECULAR 近似来源彩色反射率；完整原版 BRDF、材质常量和细分位移尚未移植。配置与 DXBC 证据见 `terrain/native_materials.json`、`native-recovery/landscape-shader/`。

## 山体模型

六种山体从 G1MG 恢复半精度切线及符号，按来源顶点位置、UV 匹配导入顶点，保持网格和颜色贴图。切线符号存入顶点颜色 alpha。补入缺失的反射率/粗糙度纹理，并按 PB2-Gbi 原式使用副切线 X、切线 Y 和法线 Z：`cross(tangent, normal) * tangent.w`。移除人为灰化、亮度修饰和法线强度削弱。

Displayset、纹理状态、KTID 绑定、来源纹理的追踪记录为 `model-materials.json`，切线证据为 `mountain-tangents.json`。未确认的遮蔽槽和材质乘数不强行绑定。

## 全地图原始植被分布

对象 `e518bbfb` 位于 `KIDSSystemResource_b43fcef2.kidsobjdb`。它是元数据对象，不是资源文件注册项。已恢复 2048 米范围、1024² 原始 ResourceMap 和 DensityMap，63011 个绘制单元；27 个元素的模型、缩放、标志和种子；14 类生境和元素组合；更新、释放及可见距离配置。

补入此前漏导入的三种秋冬树木/平面地被模型，项目累计 58 个地图模型。植被使用 14 种模型、19 层颜色数组与 64 米空间批次。远景沿用相同位置，不按缩放重新散布或减少植被。

原版分布范围与参数已恢复。当前 MT19937 采样器使用来源种子，把元素密度解释为每 2 米单元的概率。原版 PRNG、密度单位及季节转换仍未恢复，因此逐株位置仍为重建。缓存为 7460 棵树、3274 处地被；关口墙脚过滤 1 棵，运行时 7459 棵。完整来源记录为 `vegetation/native_procedural.json`；缓存声明见 `autumn_vegetation.json`。

## 原始水面及河岸

活动场景 StreamWater 显示配置 `ecb1e6a0` 的纹理状态 `2415f7db` 引用绑定表 `065ab611`，两个纹理对象 `4cf245dc` / `a41036bb` 均引用 G1T `bf537a03` 的 0/1 槽。两张 512² 法线已按原始像素导出；活动着色器为 `529eb4e6` / SWATER。`shaders/rtk14_native_water.gdshader` 使用其 R×A、G 解码及双法线合成方式。来源链和 SHA 见 `water/native_water.json`，反汇编见 `native-recovery/water-shader/`。

河面由旧四米无索引网格改为一米索引网格，共 50 个非空分块、448797 个顶点、809140 个三角形。运行时按原始水域掩码裁掉岸外片元，并为分块生成 LOD 与压缩缓存；缓存以二进制网格 SHA 区分。后续启动复用全部 50 块，不再次生成网格。地形来源高度未改变。

水位仍取重建缓存；海面高度、法线纹理周期、流速、颜色、粗糙度和反射环境并非已证实的原版配置。当前河面仍显得偏平，不能将原始法线导入等同于完整水面渲染还原。

## 地形色彩空间对照

读取 G1T 标志并记录到 `native-recovery/terrain-color-space.json`。按 [gust_tools 的 G1T 实现](https://github.com/VitaSmith/gust_tools/blob/master/gust_g1t.c) 解码，颜色纹理未标记 sRGB；但原游戏运行时纹理格式覆盖及输出转换尚不明确。不能仅凭资源标志决定 Godot 采样方式。

`tools/rtk14_terrain_color_probe.gd` 在独立进程对照两种采样方式；`--linear` 使用专用诊断着色器，不修改主场景。线性对照图 `validation/terrain-color-linear.png` 显著泛白，因此当前正式地形设置保留。完整原作色调仍需恢复运行时材质和光照，而非继续手工染色。

## 验证和性能

`tools/validate_rtk14_native_maps.py` 独立核对原始高度 4198401 个样本、地表控制字节及 1048576 单元植被分布/密度，全部与来源二进制一致。生成植被均处于来源绘制生境。纹理周期与原版烘焙图独立对应，五类材质正确周期相关系数约 0.766～0.925，错误的十分之一或十倍周期接近无相关。

`tools/validate_rtk14_models.py` 检查 58 个模型的来源绘制范围及颜色贴图绑定。Godot 场景检查覆盖 64 个地形块、1120 条来源摆放、46 城、10 关、来源切线和近远植被数量。实际 Vulkan 截图为 `docs/validation/native-world-{hanzhong,luoyang,gate,overview}.png`。

性能报告 `docs/validation/performance-native-world.json` 开启正常地图更新，使用 RTX 3060 Laptop、Vulkan Forward+、1260×710、流畅模式、0.67 渲染比例、FSR、TAA、关闭垂直同步。每视角预热 12 帧、采样 45 帧并报告中位数/P95。城市标记增加屏幕裁剪，仅在内容变化时重绘。数据不是最高画质或全部设备的性能保证。

上述报告为接入新水面之前的历史基线。最新 `validation/performance-native-water.json` 同规格开启正常更新，包含新水面及当前战役 UI：

| 视角/画质 | 中位帧时 ms | FPS | P95 ms | 可见绘制次数 |
| --- | ---: | ---: | ---: | ---: |
| 洛阳流畅 | 3.788 | 264 | 4.086 | 268 |
| 洛阳精细 | 5.074 | 197 | 5.646 | 268 |
| 全国流畅 | 4.087 | 245 | 5.339 | 764 |
| 近远切换流畅 | 2.881 | 347 | 3.477 | 356 |
| 返回洛阳流畅 | 3.213 | 311 | 4.494 | 268 |

`tools/validate_rtk14_water.py` 独立读取 G1T BGRA8 像素，确认导出两张法线全部 524288 个像素相同；检查全部水面顶点与缓存高度、索引范围、一米三角形面积及文件哈希。结果见 `validation/native-water-check.json`。这不验证重建水位的原作准确性。最终场景检查 `validation/native-water-validation.log` 通过；新水面汉中/洛阳截图为 `validation/native-water-{hanzhong,luoyang}.png`。

一米采样和来源可见清单接入后的实测：

| 视角/画质 | 中位帧时 ms | FPS | P95 ms | 可见绘制次数 |
| --- | ---: | ---: | ---: | ---: |
| 洛阳流畅 | 3.313 | 302 | 13.123 | 258 |
| 洛阳精细（1.0 分辨率、SSIL 开启） | 4.387 | 228 | 4.884 | 258 |
| 全国流畅 | 2.783 | 359 | 3.086 | 715 |
| 近远切换流畅 | 2.663 | 376 | 3.158 | 330 |
| 返回洛阳流畅 | 3.059 | 327 | 3.486 | 258 |

首轮流畅采样有约 13 毫秒的 P95 波动，返回视角的 P95 为 3.486 毫秒；这些短样本不应当解释为长期稳定帧率保证。网格缓存复用检查为 64 块全部复用，无重建；压缩缓存约 106.5 MiB。最终截图使用 1600×1000，汉中、洛阳和关口为精细模式，全国为流畅模式。

汉中改用来源 B 类圆角浅色石墙城池，与用户提供的汉中参考图作视觉对应；中型阶段仍为重建选择。完整原始 A/B/C 三类各阶段及 D/E 类型实拍见 `validation/native-city-archetypes.png`。

仍未完成：动态地格精确转换、各城样式/阶段、关口朝向/尺度、原版逐株算法、季节转换、可见性额外运行时修改、光照与后处理、水位/水面渲染、材质常量和细分位移。来源数据一致不能替代参考图逐像素验证。

## 重建顺序

`--source` 指向含元数据、G1M/G1T 和 Noesis 的 `rtk14-assets` 提取目录；`--game` 为只读游戏来源目录。

1. `extract_rtk14_terrain.py` → `recover_rtk14_landscape.py` → `build_world_landscape.py`。
2. `recover_rtk14_model_materials.py` → `export_rtk14_material_textures.py`。
3. `recover_rtk14_vegetation.py` → `import_rtk14_vegetation_models.py` → `build_autumn_vegetation.py`。
4. `recover_rtk14_stage_visibility.py`、`recover_rtk14_mountain_tangents.py`。后者须在完整模型重新转换之后执行，以免 GLB 来源切线被覆盖；山体模型可用于资源查看，当前地图按来源可见清单显示。
5. `recover_rtk14_water.py` → `build_rtk14_water_mesh.py`。
6. Godot 资源导入、场景检查、模型/地表/水面 Python 来源检查，再执行实际 GPU 截图与性能检查。
