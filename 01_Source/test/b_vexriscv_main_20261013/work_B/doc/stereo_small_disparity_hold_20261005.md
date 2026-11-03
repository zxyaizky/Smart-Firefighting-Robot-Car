本次针对 B 屏幕 D 仍有1～2格跳动，调整稳定结果的发布规则。用户已确认重新生成并下载了上一版梯度匹配比特流；本次新修改尚未下板。

原规则只要求连续两次均值离开迟滞带的方向一致。两个候选值可以不同，例如先17、再18，也可能在第二次更新显示。这会让短暂的小扰动穿过滤波。

现在原 median3、mean4、±0.75D 迟滞保持；同一目标、同一有效连续历史内，候选与已显示 D 相差1～2格时，必须连续四次有效结果得到相同的取整候选才更新。候选改变则本次新候选从1开始计数；回到迟滞带内、匹配失败、重新初始化或较大变化均取消小候选计数。空闲时钟不计次数。

较大变化沿用原来连续两次同方向的发布规则，允许候选本身变化，避免持续移动一直等待“完全相同”。小变化确认与大变化方向确认各自清除对方状态，不能相互借用已经累计的次数。

模式2保持：一次无效完成仍立即隐藏绿色框和 D/Z。近期同目标测距间断可以保留内部过滤历史，但取消确认计数。新有效测量仍是显示有效的必要条件。原始 D、bbox 和帧ID仍随各自完成事件发布；稳定 D、按7143/D得到的 Z 和绿框投影保持一致。

实际生产文件只改两项：td_project/import/stereo_hdmi_result_latch.v 增加可选 SMALL_STEP_CONFIRMATIONS 和小候选计数；user_source/hdl_source/design_top_wrapper.v 在 B 实例启用 SMALL_STEP_CONFIRMATIONS=4。默认值2逐周期保留原行为。

A 的源码、NPU阈值、B匹配算法和资格阈值、距离常数7143、logo、自动曝光、摄像头/HDMI时序、引脚、工程文件及约束保持原样。

七套 RTL 仿真全部通过，编译及仿真0 errors、0 warnings：

{
  "tb_stereo_range_stability": [
    "# PASS stereo_range_stability samples=110 checks=1451 independent_integer_history_oracle"
  ],
  "tb_stereo_stable_label_overlay": [
    "# PASS stable_label_overlay cases=18 checks=2838844 full_rasters=3"
  ],
  "tb_stereo_range_stability_stream": [
    "# PASS stereo_range_stability_stream inputs=84 outputs=82 checks=990"
  ],
  "tb_stereo_range_hysteresis": [
    "# PASS stereo_range_hysteresis samples=7218 checks=97482 steps=961 sum65=44 sum66=62 opposite=6 neutral=4"
  ],
  "tb_stereo_range_gap": [
    "# PASS stereo_range_gap checks=239 hidden failures bounded history reset contexts full_rate"
  ],
  "tb_stereo_range_small_step": [
    "# PASS STEREO_RANGE_SMALL_STEP samples=11342 outputs=11341 checks=1214160 steps=930 max_step=8 old_jitter=40 new_jitter=0 changed_q=275 neutral=50 opposite=1 class=527"
  ],
  "tb_stereo_small_step_legacy_equivalence": [
    "# PASS stereo_range_hysteresis samples=7218 checks=97482 steps=961 sum65=44 sum66=62 opposite=6 neutral=4"
  ]
}

新增对比包括11,342次完成输入、1,214,160项检查、930个真实非零整数阶跃、连续上下移动、候选改变/中性/反向/大小变化切换、无效结果隐藏与确认重置、ID回绕和重复、历史超时、复位及256次满速完成FIFO。另有默认参数逐拍对照修改前模块，覆盖原迟滞回归的全部输出。

短暂±2扰动序列（每次两帧扰动后恢复十帧）中，旧显示改变40次，新显示改变0次。这是已知合成输入的稳定性测试，不是实拍统计。

同目标连续有效恒定阶跃最多八个新有效结果跟上；±1格需要七个，+2格需要七个、−2格需要八个。按每秒五次有效测距计算，小幅真实移动可能约1.4～1.6秒才反映到显示。无效帧或候选不一致会延长等待，不能把NPU FPS直接当成有效测距率。

稳定发布只减少短期显示抖动，不增加视差分辨率，也不修正持续误匹配。目标重新建立历史时会立即初始化，因此本修改不能保证所有实拍条件下 D 完全不变。

备份：C:/Users/lx292/.codex/visualizations/2026/10/02/01a0fcfc-febf-7073-bbf8-a7bb4ec51c05/stereo_small_disparity_hold_20261005/before/B；源码差异：C:/Users/lx292/.codex/visualizations/2026/10/02/01a0fcfc-febf-7073-bbf8-a7bb4ec51c05/stereo_small_disparity_hold_20261005/source_changes.patch；验证记录另存 simulation/stereo_range_stability/verified_small_step_20261005.json，原有历史验证记录保持。

最终生产SHA-256：

{
  "td_project/import/stereo_hdmi_result_latch.v": "512261ca3e543ffdbd966fe4c0a2b7421429b05d7b37298764804cb27db1363b",
  "user_source/hdl_source/design_top_wrapper.v": "d5fa308eff273246f24a0eba344cf8a5cb7e7020f6b07f97722eee44dec61472"
}

读取到的上一版 routed报告生成于2026-10-05 18:51:50，setup WNS=+0.070ns、hold WNS=+0.020ns。该报告不是本次新源码的实现验证。

本次仅修改源码、仿真及保存本地Git，未启动TD、综合、布线、生成比特流、下载或上传GitHub。新版时序和实拍效果尚未验证。
