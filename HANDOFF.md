# Handoff：Kazumi-Kai (改) iPadOS 26+ 视频增强完整实现与交付文档

> 本文档详细记录 Kazumi-Kai 在 iPadOS 26+ 设备（iPad Pro M4）上基于 VideoToolbox（VT）与 Metal 硬件加速实现实时视频插帧、超分辨率放大、双开自适应降档及色彩精确校正的完整架构、迭代历史与运维指南。

---

## 1. 项目概述与最终状态

### 1.1 核心功能
1. **低延迟动态插帧（24 fps → 48 fps）**：
   - 基于 Apple iOS 26+ `VTLowLatencyFrameInterpolation`（`phase [0.5]`），在相邻帧之间由神经网络引擎（ANE）生成高精度中间帧。
   - 彻底解除 Flutter 24 fps 合成瓶颈，直接由 120 Hz `CADisplayLink` 驱动主线程无锁选帧，真机实测稳定 **48.1 fps** 呈现。
2. **低延迟超分辨率放大（1080p → 4K / 1.5x）**：
   - 基于 `VTLowLatencySuperResolutionScaler`，针对 iPad Pro M4 单块最大 `1280x1280` 硬件限制，实现 2×2 自适应无缝瓦片（Tiling）拆解与缝合。
   - 实现 ANE 推理与 GPU 瓦片裁剪流水线重叠（Pipeline Overlap），单开 4K（`3840x2160`）实测满帧 **24.0 fps**，0 丢帧、0 超时。
3. **双开自适应降档（1.5x）与动态热切换**：
   - 提供「双开时超分调整至 1.5x」自适应开关：插帧与超分同时启用时，超分档位自动调整至 1.5x（`2880x1620`），像素渲染量减少 44%，显著降低 ANE 功耗与发热降频，保证双开帧率稳定。
   - 支持播放中通过设置页或播放器快捷菜单无缝热切换（Hot-Swap），无黑屏、无卡死、无帧序错乱。
4. **色彩与亮度精确还原（零 Gamma 偏移 / 零闪烁）**：
   - 全面抛弃 CoreImage `CIContext`（其 `itur_709` 色域含 Apple 1.96 场景 Gamma 曲线，会导致画面泛白亮化）。
   - 实现定制 Metal Compute Shader 线性管线，严格依据 ITU-R BT.709 Limited-Range（Y `16–235`，CbCr `16–240`）矩阵进行转换，无任何 Gamma 曲线改动。
   - 最终统一以未标记色域的 `32BGRA` 直接交付 Flutter 外置纹理，完全绕过 Flutter Impeller 内部硬编码的 BT.601 `YuvToRgbFilter`，彻底消除色彩闪烁并保持画面与原画 100% 一致的亮度与对比度。

### 1.2 最终状态
- **编译状态**：iPhoneOS 26.5 SDK / iPhoneSimulator / macOS 10.15 三端 `swiftc -typecheck` 0 警告 0 报错通过；`xcodebuild Release` 无签名构建打包通过。
- **发布产物**：[Kazumi-unsigned.ipa](file:///I:/APP/Kazumi-Kai/dist/Kazumi-unsigned.ipa)（~29.2 MiB）。
- **真机实测**：在 iPad Pro M4（iPadOS 26.x + LiveContainer）上验证通过：
  - 仅插帧：`fps=48.1`，`copy=48`，画面流畅丝滑。
  - 仅超分：`fps=24.0`，`out=3840x2160:BGRA`，瓦片无接缝，清晰度显著提升。
  - 双开模式：色彩闪烁彻底消除，亮度与原生播放完全一致；开启 1.5x 降档后输出 `2880x1620:BGRA`，温控与流畅度表现优异。

---

## 2. 渲染架构与数据流

### 2.1 整体渲染管线

```
mpv_render_context (OpenGL ES 3.0 FBO)
  │
  ▼
CVPixelBuffer (32BGRA, 1080p, 未标记色域)
  │
  ▼ [TextureHW.render - 渲染工作线程]
IOS26VideoEnhancer.submit(source, pts, frameIndex)
  │
  ├─ 1. MetalFrameProcessor: 拷贝 BGRA 帧至自管理池 (持有跨帧生命周期)
  │
  ├─ 2. 解码帧发布 (Decoded Frame):
  │     ├─ 无超分时: 直接作为 32BGRA 提交 emit()
  │     └─ 有超分时: 送入 VTFrameScaler 处理
  │
  ├─ 3. VTFrameInterpolator (插值帧生成):
  │     ├─ Metal Kernel (bgra_to_nv12): 32BGRA → 420v (精确 BT.709 Limited Range)
  │     ├─ VTLowLatencyFrameInterpolationParameters: [previous(420v), source(420v), phase: 0.5]
  │     ├─ VTFrameProcessor.process(with:) -> destination(420v)
  │     ├─ BlankCheckBudget: 校验 420v Y 平面 (防全零帧/暗绿帧)
  │     ├─ 若无超分: Metal Kernel (nv12_to_bgra) 还原为 32BGRA -> emit()
  │     └─ 若有超分: 直接以 420v 送入 VTFrameScaler -> emit()
  │
  └─ 4. VTFrameScaler (超分辨率放大):
        ├─ 瓦片分解 (Tile Plan):
        │   - 若 <= 1280x1280: 单瓦片直接推理
        │   - 若 > 1280x1280 (如 1080p): 拆分为 2x2 瓦片 (960x544, 重叠 32px)
        ├─ 重叠执行 (Pipeline Overlap):
        │   - GPU Metal 裁剪当前瓦片输入
        │   - ANE VideoToolbox 执行超分推理
        ├─ BlankCheckBudget: 瓦片 420v 校验
        └─ Metal Kernel (nv12_to_bgra / bgra_patch):
            直接缝合非重叠核心区至 32BGRA 目标池 (3840x2160 或 2880x1620)
  │
  ▼
EnhanceFrameQueue (容量 8，严格按 PTS 升序排列)
  │
  ▼ [VideoOutput.swift - 主线程 120 Hz CADisplayLink]
handleDisplayTick()
  │
  ├─ TextureHW.selectFrame(at: playbackClock):
  │     ├─ 插帧模式: playbackClock = clockAnchorPTS + elapsed (滞后 2 帧防断流)
  │     │   - EnhanceFrameQueue.nearest(to: clock)
  │     │   - 严格保证 PTS 单调递增 (防逆序抖动)
  │     └─ 非插帧模式: newestEnhanceFrame() 零滞后直出
  │
  └─ 若选帧变更 (changed == true):
        调用 textureFrameAvailableDirect() 直接通知 Flutter 引擎
  │
  ▼
Flutter Raster 线程 (FlutterDarwinExternalTextureMetal)
  │
  └─ copyPixelBuffer() -> 获取选中的 32BGRA CVPixelBuffer
        直接上传至 MTLPixelFormatBGRA8Unorm (零色域/Gamma 转码开销)
```

---

## 3. 核心技术点与硬件限制避坑总结

### 3.1 iPad Pro M4 VideoToolbox 硬件能力实测
- **`VTLowLatencySuperResolutionScaler` 硬件规格**：
  - `maximumDimensions`：`1280x1280`；`minimumDimensions`：`96x96`。
  - 对于 `1920x1080` 画面，直接调用 `startSession` 或推理会返回空格式或报错 `-19730 (Processor is not initialized)`，必须采用分块瓦片处理。
  - 对于 2x2 瓦片（`960x544`），M4 原生支持档位为 `scales=[1.5, 2.0]`，像素格式要求为 `420v`（`kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`）。
- **`VTLowLatencyFrameInterpolation` 硬件规格**：
  - 原生支持 1080p（`1920x1080`），单次插值帧数为 1（`numberOfInterpolatedFrames: 1`），输入与输出必须为 `420v`。
  - 不支持 `spatialScaleFactor: 2`（该组合会抛出 `-19730` 错误），插帧与超分必须拆分为两级独立处理器。

### 3.2 色彩与 Gamma 陷阱（整体泛白与闪烁的根本原因）
1. **CoreImage Gamma 陷阱**：
   - `CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.itur_709)!])` 在将 `32BGRA` 转换为 `420v` 以及由 `420v` 还原时，强制套用了苹果历史规范中的 ~1.96 场景 Gamma 曲线，相比 mpv 渲染的 BT.1886/sRGB（~2.2–2.4）显著提亮了中间调，造成“整体画面变灰白”。
2. **Flutter Impeller 外部纹理硬编码陷阱**：
   - 检查 `Flutter.framework` 二进制可知，`FlutterDarwinExternalTextureMetal` 在接收到 `420v` 纹理时，并不读取 `CVBufferAttachment` 附带的 `kCVImageBufferYCbCrMatrixKey` 或 `kCVImageBufferTransferFunctionKey`，而是统一送进其内置的 `YuvToRgbFilter` 按 `BT.601 Limited-Range` 矩阵转为 RGB。这直接导致 1080p/4K 的 BT.709 视频出现饱和度不足与暗部偏离。
3. **解决方案**：
   - 自研 Metal Compute 着色器，严格按照 ITU-R BT.709 Limited Range 公式双向无损转换：
     $$Y = \frac{16 + 219 \times (0.2126R + 0.7152G + 0.0722B)}{255}$$
     $$Cb = \frac{128 + 224 \times (-0.114572R - 0.385428G + 0.500000B)}{255}$$
     $$Cr = \frac{128 + 224 \times (0.500000R - 0.454153G - 0.045847B)}{255}$$
   - 向 Flutter 输出时统一合成/转换为无标记的 `32BGRA`，Flutter 仅需作为纯 RGB 纹理贴图渲染，色彩表现与关闭增强时 100% 一致。

### 3.3 帧呈现驱动机制（48 fps 满帧关键）
- 原版通过 `WorkerQueue` 与 mpv 出帧回调（24 fps）驱动，外加 `asyncAfter` 定时器唤醒。由于多线程调度延迟，定时器常被下一真实帧抢占或取消，导致呈现速率死锁在 24 fps。
- 最终方案：由主线程 120 Hz `CADisplayLink` 独占呈现控制权，每 8.33 ms 检查一次平滑推进的 `playbackClock`，只要队列中有新的 PTS 帧就立即切换并通知 Flutter，彻底跑满 48.1 fps。

### 3.4 绿屏防护机制（BlankCheckBudget）
- VideoToolbox ANE 后端在尺寸或内存池属性未完全对齐时，API 会返回成功但实际 destination 写入全零。
- `420v` 的全零内存（$Y=0, Cb=0, Cr=0$）在转为 RGB 时并非黑色，而是高饱和度**暗绿色**（$G \approx 135$）。
- `BlankCheckBudget` 在首批 30 帧每帧检测，后续每 240 帧抽检一次，采样 Y 平面判定是否小于 20（合法黑场 $Y=16$）。若检测到全零缓冲立即重置并上报，避免向屏幕输出绿屏。

---

## 4. 关键源码分布

### 4.1 media-kit 插件（iOS 增强核心实现）
路径：`media-kit/media_kit_video/`

| 文件相对路径 | 核心修改与职责 |
|---|---|
| `common/darwin/Classes/plugin/VideoOutput.swift` | 维护 120 Hz `CADisplayLink`，主线程直接选帧，消除 worker 队列跳跃与定时器取消问题 |
| `ios/.../plugin/TextureHW.swift` | 私有 OpenGL 纹理包装器，管理时钟锚点更新、PTS 单调性校验、重置防冻结逻辑 |
| `ios/.../plugin/enhance/FrameEnhancerProtocol.swift` | 定义 `EnhanceFrame`（像素缓冲与 PTS 绑定）、有序队列及最近邻选帧接口 |
| `ios/.../plugin/enhance/PixelBufferConverter.swift` | **核心重构**：Metal Compute Shader 实现精确 BT.709 转换、瓦片裁剪与 4K 缝合 |
| `ios/.../plugin/enhance/VTFrameInterpolator.swift` | 封装 `VTLowLatencyFrameInterpolation`，双缓冲输入队列，Y 平面全零检测 |
| `ios/.../plugin/enhance/VTFrameScaler.swift` | 封装 `VTLowLatencySuperResolutionScaler`，2x2 瓦片调度计算，整除偶数保护 |
| `ios/.../plugin/enhance/VideoEnhancer.swift` | 管线总调度器，统一管理解码帧与插值帧的超分流通，输出纯净 32BGRA |

### 4.2 Kazumi 播放器应用（配置与 UI 控制）
路径：`Kazumi/lib/`

| 文件相对路径 | 核心修改与职责 |
|---|---|
| `services/storage/settings_keys.dart` | 注册 `videoEnhanceDualScale15x` 等全部配置键，纳入 `SettingsKeys.all` |
| `pages/settings/super_resolution_settings.dart` | 设置界面增加「双开时超分调整至 1.5x」自适应降档开关及多档位说明 |
| `pages/player/controller/player_playback_controller.dart` | `watchEnhanceSettings` 监听降档键，`_buildEnhanceConfiguration` 动态计算 1.5x 倍率 |
| `pages/player/player_item_panel.dart` | 播放器底部快捷菜单动态显示 `1.5x` / `2x` 档位状态 |

---

## 5. 本地构建与打包运维指南

本地环境采用 WSL2 + Docker-OSX Tahoe 容器，无需公网远程 macOS 主机。

### 5.1 构建脚本规范
1. **VM 启动与保活**：
   - 严禁使用 `docker start DESKTOP-DLL4GUN`（会因只读挂载 `Launch.sh` 导致 `Device or resource busy`）。
   - 必须通过 `.tmp/ensure-vm.sh`（自动 `docker rm -f` 并执行 `~/Docker-OSX/tahoe/tahoe.sh` 启动，监听 SSH `127.0.0.1:50922`）。
2. **自动化增量编译与打包**：
   - 执行脚本：`.tmp/rebuild.sh`。
   - 流程：
     1. 将修改后的 Swift 与 Dart 文件同步至 VM 临时区并覆盖对应仓库。
     2. 在 VM 上自动执行三平台 `swiftc -typecheck`（iPhoneOS 26.5、iPhoneSimulator、macOS 10.15）。
     3. 执行 `xcodebuild -workspace Runner.xcworkspace -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO`。
     4. 打包为 `Kazumi-unsigned.ipa` 并导出到 `dist/Kazumi-unsigned.ipa`。

### 5.2 安装部署（LiveContainer HTTP API）
- 使用工具：`I:\APP\livecontainer_dev\docs\lcapi.py`。
- 命令：
  ```bash
  python I:\APP\livecontainer_dev\docs\lcapi.py --host 192.168.2.4 --port 8888 --token <LC_TOKEN> install I:\APP\Kazumi-Kai\dist\Kazumi-unsigned.ipa --overwrite
  ```
- 注意事项：安装时 iPad 上的 LiveContainer 必须处于**前台激活状态**，否则 TCP 会因系统冻结而断开（报错 `WinError 10053`）。

---

## 6. 状态行诊断对照表

在播放器内开启 FPS 监控覆盖层后，状态行格式如下：
```
active: interp 2x + scale 1.5x [scale:2x2:yuvAsync:420v->BGRA] 1920x1080 → 2880x1620 | frames=... emit=... push=... | interp submit=... ok=... | scale[2x2:yuvAsync:420v] submit=... ok=... | out=2880x1620:BGRA | renders=... submits=... select=...
```

| 诊断字段 | 正常期望值 | 异常特征及排查方向 |
|---|---|---|
| `out=` | `WxH:BGRA` | 必须为 `BGRA`；若显示 `420v` 说明未走 Metal 还原管线，会触发 Impeller 偏色 |
| `scale[2x2:...:420v]` | `ok` 持续自增，`fail=0`，`to=0` | 若 `fail` 增长：检查分辨率是否超出 1280 瓦片限制；若 `to` 增长：检查 Metal 锁冲突 |
| `interp` | `ok` 持续自增，`fail=0`，`to=0` | 若 `ok` 为 0：检查 `sourcePixelBufferAttributes` 是否遗漏 |
| `select=` | 约 `48` 次/秒变更 | 若停留在 `24` 次/秒：检查 `CADisplayLink` 是否被后台限频 |
| `miss=` | `same buffer` 或偶发 `older pts` | 若持续 `empty queue`：说明推理管线阻塞，队列已饿死 |
