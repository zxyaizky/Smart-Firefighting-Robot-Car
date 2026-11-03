# B板本地图像处理恢复

工程：`C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B\td_project\camera_to_dsi_display_lidar.al`。

C7循环：原图（绿点修复）→均衡化灰度→灰度中值→Sobel细边缘→卡通化→运动区域→帧差→原图。B4高电平/关闭侧显示本地B板画面，低电平显示A板网络画面。

接入内容：

- 原始Y→3×3灰度中值→Sobel，阈值60，开启方向非极大值抑制，白边黑底。
- 卡通支路保留RGB中值、暗部提亮、六级分层、阈值180深色轮廓。复用rgb_quantize_4原有RGB三拍对齐，RGB使用原始流，控制使用同步延迟的YCbCr流。
- 原图复用D:/lab_ex3_osdb优化版rgb_green_impulse_filter，只修复符合条件的单点/相邻两点G通道：G比R/B高32以上，比两像素外背景G高48以上，背景及R/B差异≤32，用两侧背景G均值替换。连续绿色内部/边缘、低对比绿色和行首尾两点保留。符合异常条件的真实细小绿色细节也可能被修正。
- 原图RGB、DE、VS整体延迟4拍，无行RAM。识别继续取原始RGB，不改变黄绿识别、云图目标、机械臂/喷水或语音条件。

片段：rtl/rescue/display_effects.vh；生成步骤：integrate_display_effects.py，由integrate_rescue.py调用。新滤波源码私有登记到lidar工程，共享算法、来源工程、A板、CPU、DDR和引脚不改。恢复模块的AutoExcluded标记已清除，integrate.py重复生成保持一致。

验证：`python test_display_effects.py`编译正式登记RTL，以真实顶层抽取接线检查四项算法及七模式。新增NPU帧率模块后，工程共198份RTL。独立NumPy参考对比六个输出支路，每支路88064像素，共528384次像素比较，覆盖48×16、最短1拍行空白及1280×8；行宽/帧数、DE/VS和0→6→0切换均通过。未改的直方图和运动算法在这组测试中使用确定接口输入，不计为本次重新验证的算法。

绿点单测覆盖7558周期、74个修复点，含单/双点、真实连续绿色、边界、1280宽随机行、亮背景防溢出及活动中复位。控制器、语音/小车串口、实际救援顶层回归通过。TD从正式工程展开确认四个实例；213保护文件、9个CPU/视频/地图实例、51引脚审计通过。

后续布线优化保留全部算法：灰度中值的有效信号继续复位，纯算术流水线取消冗余复位；卡通RGB中值共享一组窗口控制和行地址，保留各通道中值运算。150000周期对比（含复位、输入间隙）和528384次独立像素参考比较均通过。HDMI末级新增NPU检测帧率，见NPU_FPS.md。

当前198份源码已通过正式TD综合，完整物理阶段按用户允许的30分钟上限验证中；尚未验收，历史20分钟内结果不能作为本版成绩。本次没有生成bit或下板。新bit生成后再合并Flash；Linux及MCU载荷不变。

记录：`C:\Users\lx292\Desktop\qiansai_last\test\b_vexriscv_main_20261013\work_B\reports\display_effects_restore_20261031_095140`。
