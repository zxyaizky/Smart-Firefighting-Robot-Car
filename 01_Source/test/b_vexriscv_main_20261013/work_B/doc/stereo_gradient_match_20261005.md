本次针对 B 板 D 跳变，在每个窗口内启用梯度匹配排序。A 板识别源码和检测阈值保持原值。

原匹配以 25 个像素的绝对灰度差总和寻找最小值。两路图像即使位置对应正确，也可能因整体亮度不同而产生较大的灰度差，让错误位置胜出。

新匹配对每一个 D 先检查原有 raw SAD 门限，再比较每行相邻像素的明暗变化，共 20 个横向梯度项。未裁剪像素的恒定亮度偏移在梯度中抵消。梯度成本相同则比较 raw SAD；两项均相同保留较小 D。最终 match_cost 仍是所选 D 的原 raw SAD。

参数保留：D=1～31、raw SAD<=1500、右模板纹理>=8、读超时16拍、距离常数7143。三个 5×5 窗口、全部有效时取三个视差中位数、较少有效窗口时取最低 raw SAD 候选均保持原行为。相同完整 RAM 图像下，新旧窗口的有效集合相同；此次没有额外拒绝门槛。

框和 D/Z 继续共用现有稳定视差。下一次匹配失败仍隐藏结果；没有增加沿用无效距离作为有效测距的行为。当前滤波参数、logo、自动曝光、引脚、HDMI/摄像头时序、工程和约束文件均未改变。

实际生产修改仅两项：

- td_project/import/stereo_roi_ranging.v：增加 GRADIENT_RANKING 默认0，分拍计算梯度及其累加，保持默认模式的逐周期兼容性。
- user_source/hdl_source/design_top_wrapper.v：只在 B 实际 ROI 实例启用 GRADIENT_RANKING(1)。

梯度项9位，最大510；累加14位，20项最大10200。每像素增加一个计算周期，完整三窗口31个视差最多增加2325拍，约31微秒（75 MHz）。RAM 请求数量、顺序、坐标及帧对身份不变，视频链路没有新增流水拍。

完成的六个独立 RTL 测试均通过，编译及仿真为0 errors、0 warnings：

- roi_multi_tb: PASS
- tb_stereo_roi_ranging: PASS
- tb_stereo_roi_pair: PASS
- tb_stereo_roi_pair_gradient: PASS
- tb_stereo_roi_legacy_equivalence: PASS
- tb_stereo_gradient_match: PASS

新增算法对比覆盖63个场景、1,173,753项检查。已知真实D=8的整体亮度偏移场景，旧算法选D=20，新算法选D=8；局部曲率坡度场景，旧算法选D=6，新算法选回D=8。这些是已知输入的合成测试，不能代替实拍准确率统计。

各项摘要：

{
  "roi_multi_tb": [
    "# PASS ROI_MULTI cases=24 production7143/1500/8 unchanged thresholds"
  ],
  "tb_stereo_roi_ranging": [
    "# PASS stereo_roi_ranging cases=26 shift/ROI/thresholds"
  ],
  "tb_stereo_roi_pair": [
    "# PASS stereo_roi_pair frames=5 actual Stage5 banks locks concurrent writes autoaccept done"
  ],
  "tb_stereo_roi_pair_gradient": [
    "# PASS stereo_roi_pair frames=5 actual Stage5 banks locks concurrent writes autoaccept done"
  ],
  "tb_stereo_roi_legacy_equivalence": [
    "# PASS stereo_roi_ranging cases=26 shift/ROI/thresholds"
  ],
  "tb_stereo_gradient_match": [
    "# PASS STEREO_GRADIENT_MATCH cases=63 checks=1173753 evaluated=4645 max_gradient=10200 max_sample=510 production7143/1500/8"
  ]
}

独立源码审查也通过。原版模式逐拍对比所有17个输出，包括请求地址、握手、busy、有效位及结果数据。真实双 RAM 测试验证已锁银行不被新帧覆盖，输入元数据变化不改变已接受帧对。具体哈希和测试证据随 simulation/stereo_gradient_match/verified_20261005.json 保存。

原始生产文件完整备份：C:/Users/lx292/.codex/visualizations/2026/10/02/01a0fcfc-febf-7073-bbf8-a7bb4ec51c05/stereo_gradient_match_20261005/before/B。源码差异：C:/Users/lx292/.codex/visualizations/2026/10/02/01a0fcfc-febf-7073-bbf8-a7bb4ec51c05/stereo_gradient_match_20261005/source_changes.patch。

最终两项生产 SHA-256：

{
  "td_project/import/stereo_roi_ranging.v": "04bc0feba6264b6c9aaccb229f4506a1c091eb457b9273fe1da9c7252be2594b",
  "user_source/hdl_source/design_top_wrapper.v": "b06d19254c00f5f98014ae2bc126032a31e4ce52e2898dfe1e6a582ba2b956cc"
}

局限：横向梯度不是标定、垂直校正或亚像素算法。饱和、增益变化、重复纹理、强噪声及火焰图像随时间变化仍可能误配；仅有垂直纹理的窗口梯度区分能力有限。整体亮度差超过平均每像素60时，真实候选仍可能被保留的1500 raw SAD 门限排除。该修改不保证消除所有1～4格实拍跳变，也不将过滤稳定等同于测量更精准。

读取到的旧布线报告（2026-10-05 17:07:23）setup WNS=+0.003 ns、hold WNS=+0.020 ns，当前旧设计检查通过。此报告早于本次梯度源码，不代表新设计综合、布线或时序已通过。

本次仅修改源码、执行 RTL 仿真并保存本地 Git；未启动 TD、综合、布线、生成比特流、下载或上传 GitHub。板上效果需要用户之后用新 B 源码生成并下载，再固定目标比较。A/B 受保护源码、模型及比特流的应用前后完整性记录见 applied.json。
