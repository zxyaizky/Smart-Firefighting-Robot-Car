"""Create a separate TD candidate; never overwrite the accepted Wi-Fi/Flash sources."""
from pathlib import Path
import hashlib,json,re,shutil

D=Path(__file__).resolve().parent;F=D.parent;W=F.parents[1];R=W/'reports/lidar_hdmi_20261025'
BASE=W/'td_project/camera_to_dsi_display_wifi_flash.al'
PROJECT=W/'td_project/camera_to_dsi_display_lidar.al'

def main():
    for name in ['rtl','sim','build','constraints']:(D/name).mkdir(parents=True,exist_ok=True)
    (R/'before').mkdir(parents=True,exist_ok=True)
    baseline=[BASE,F.parent/'linux_wifi_flash/build/rtl/design_top_wrapper.v',
      F.parent/'linux_wifi_flash/build/rtl/vexriscv_b_subsystem.v',
      F/'tx_guard_20261025/build/u33_wifi_linux_txguard_auth900.bit',
      F/'ssh_auth900/build/Image',F/'ssh_auth900/build/rootfs.cpio.gz',F/'ssh_windows.ps1']
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in baseline}
    # TD emits an unescaped UsedInP&R attribute; preserve its native file format.
    for value in re.findall(r'<File Path="([^"]+)"',BASE.read_text(encoding='utf8')):
        path=(BASE.parent/value).resolve()
        if path.is_file():hashes[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
    proof=R/'protected_before.json'
    if proof.exists():
        for path,digest in json.loads(proof.read_text()).items():
            assert hashlib.sha256(Path(path).read_bytes()).hexdigest()==digest,path
    else:proof.write_text(json.dumps(hashes,indent=2))
    for path in baseline[:3]:
        target=R/'before'/path.name
        if not target.exists():shutil.copy2(path,target)
    for source in baseline[1:3]:
        target=D/'rtl'/source.name
        if not target.exists():shutil.copy2(source,target)
    text=BASE.read_text(encoding='utf8')
    text=text.replace('<Name>camera_to_dsi_display_wifi_flash</Name>','<Name>camera_to_dsi_display_lidar</Name>')
    for name in ['design_top_wrapper.v','vexriscv_b_subsystem.v']:
        old='../firmware/linux_wifi_flash/build/rtl/'+name
        assert text.count('Path="'+old+'"')==1
        text=text.replace('Path="'+old+'"','Path="../firmware/linux_wifi/lidar_hdmi/rtl/'+name+'"')
    addition='''            <File Path="../firmware/linux_wifi/lidar_hdmi/rtl/lidar_map_overlay.v">
                <FileInfo>
                    <Attr Name="UsedInSyn" Val="true"/>
                    <Attr Name="UsedInP&R" Val="true"/>
                    <Attr Name="BelongTo" Val="design_1"/>
                    <Attr Name="CompileOrder" Val="999"/>
                </FileInfo>
            </File>
'''
    text=text.replace('        </Verilog>',addition+'        </Verilog>',1)
    if not PROJECT.exists():PROJECT.write_text(text,encoding='utf8')
    print('LIDAR_CANDIDATE_PREPARED',PROJECT)
    print('Protected files:',len(hashes))

if __name__=='__main__':main()
