# HDMI NPU检测帧率

正式工程：`C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B\td_project\camera_to_dsi_display_lidar.al`。

最终HDMI画面的右上方（x=1080、y=56）显示 `NPU FPS:xxx`，每秒统计一次，在视频帧边界更新，避免一帧内数字撕裂。本地和A板网络画面切换时均保留此项。

计数依据是A板经以太网发送的NPU结果编号。A板每次完成推理都会增加编号，包括未检测到人员的结果；重复发送同一编号不会重复计数。小范围编号跳跃按增量计数，16位回绕正常处理；倒退或大幅跳变重新建立基准，连续一秒没有新结果后显示0。该数值反映收到的推理编号变化率，网络断流会影响显示，不是HDMI刷新率或摄像头采集帧率。

`rtl/rescue/npu_fps_overlay.v` 在云图叠加之后、HDMI编码之前组合叠字，不增加RGB、DE、VS流水延迟，不改DDR、CPU、A板源码或传输协议。顶层接线由 `npu_fps_instance.vh` 和 `integrate_display_effects.py` 维护。

`python test_rescue.py --case tb_npu_fps_overlay` 检查重复编号、跳号、回绕、无目标结果、无效来源、坏包、空闲恢复、秒边界、999饱和、完整字体和逐像素透传。用例已加入完整回归。仿真预览位于当前route20报告的 `npu_fps_preview.png`。

此功能需重新生成并下载B板bit后才能在实板生效。
