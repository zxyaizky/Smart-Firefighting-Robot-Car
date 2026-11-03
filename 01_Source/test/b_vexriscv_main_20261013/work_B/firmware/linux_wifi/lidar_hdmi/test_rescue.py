"""RTL-only regression. Does not invoke TD, program hardware, or open COM ports."""
from pathlib import Path
import argparse
import json
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET

D = Path(__file__).resolve().parent
W = D.parents[2]
OUT = W / "reports/rescue_integration_20261027"
SIM = D / "sim/rescue"
RTL = D / "rtl/rescue"
TOOLS = Path("D:/BaiduNetdiskDownload/win64")


def run(tool, args, log_name, timeout=120):
    result = subprocess.run([str(TOOLS / (tool + ".exe")), *map(str, args)],
                            cwd=OUT, capture_output=True, text=True, errors="replace", timeout=timeout)
    text = result.stdout + result.stderr
    (OUT / log_name).write_text(text, encoding="utf8")
    if result.returncode or re.search(r"\*\* (?:Error|Fatal)", text):
        raise RuntimeError(f"{tool} failed: {OUT / log_name}\n{text[-3000:]}")
    return text


def compile_design():
    OUT.mkdir(parents=True, exist_ok=True)
    run("vlib", [OUT / "work"], "vlib.log")
    manifest = (W / "td_project/camera_to_dsi_display_lidar.al").read_text(encoding="utf8")
    source_section = re.search(r"<Source_Files>[\s\S]*?</Source_Files>", manifest)[0]
    root = ET.fromstring(re.sub(r"&(?!amp;|lt;|gt;|quot;|apos;)", "&amp;", source_section))
    sources = []
    for group in ("Verilog", "System_Verilog"):
        for entry in root.findall(".//" + group + "/File"):
            attrs = {a.get("Name"): a.get("Val") for a in entry.findall("./FileInfo/Attr")}
            if attrs.get("UsedInSyn", "true") == "false":
                continue
            path = (W / "td_project" / entry.get("Path")).resolve()
            assert path.is_file(), path
            if path.suffix.lower() in (".v", ".sv"):
                sources.append(path)
    assert len(sources) == len(set(sources)), "Duplicate RTL entries"
    includes = sorted({str(p.parent) for p in sources})
    args = ["-work", OUT / "work", *["+incdir+" + p for p in includes], *sources]
    run("vlog", args, "compile_project.log")
    (OUT / "compiled_sources.json").write_text(json.dumps(list(map(str, sources)), indent=2), encoding="utf8")
    print(f"PASS registered project RTL compile ({len(sources)} sources)")


def run_case(name, source=None, extras=()):
    if name == "tb_rescue_top":
        source = make_top_fixture()
    source = source or SIM / (name + ".v")
    run("vlog", ["-sv", "-work", OUT / "work", source, *extras], name + ".compile.log")
    text = run("vsim", ["-c", "-novopt", "-suppress", "12110", "-lib", OUT / "work", name,
                       "-do", "onerror {quit -code 1}; run -all; quit -code 0"], name + ".log",
               timeout=300 if name == "tb_color_full_frame_bbox" else 120)
    assert "PASS " + name in text, text[-1200:]
    print("PASS", name)


def make_top_fixture():
    top = (D / "rtl/design_top_wrapper.v").read_text(encoding="utf8")
    parameters = re.search(r"module design_top_wrapper #\(([\s\S]*?)\) \(", top)[1]
    sections = []
    pairs = (
        ("    // Shared pre-OSD detections", "    // END SHARED_COLOR_DETECTIONS"),
        ("    // Raw network metadata is independent", "    // END B_RESCUE_CONTROL"),
        ("    // Independent fire-control branch", "    // BEGIN VEXRISCV_B_MAIN_INTEGRATION"),
    )
    for start, end in pairs:
        a = top.index(start)
        b = top.index(end, a)
        if end.endswith(";") or "END B_RESCUE_CONTROL" in end or "END SHARED_COLOR_DETECTIONS" in end:
            b += len(end)
        sections.append(top[a:b])
    a = top.index("    lidar_map_overlay #")
    b = top.index("    );", a) + len("    );")
    sections.append(top[a:b])
    # Only virtual timing/resolution changes; every connection is copied from the real top.
    core = "\n".join(sections).replace("FIRE_CONTROL_CLK_HZ = 75000000", "FIRE_CONTROL_CLK_HZ = 1000")
    fixture = (SIM / "tb_rescue_top.v").read_text(encoding="utf8")
    fixture = fixture.replace("@@PARAMETERS@@", parameters).replace("@@CORE@@", core)
    source = OUT / "tb_rescue_top.v"
    source.write_text(fixture, encoding="utf8")
    return source


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compile-only", action="store_true")
    parser.add_argument("--case")
    args = parser.parse_args()
    compile_design()
    if args.compile_only:
        return
    if args.case:
        run_case(args.case)
        return
    for name in ("tb_rescue_control", "tb_rescue_uart", "tb_rescue_mailbox", "tb_rescue_arm",
                 "tb_fire_spray_burst", "tb_rescue_top", "tb_rescue_color_overlay", "tb_npu_fps_overlay"):
        run_case(name)
    # Reuse the donor's fixtures against the candidate copies, never write the donor.
    donor_sim = Path("D:/lab_ex3_osdb/simulation")
    for name in ("tb_color_green_yellow", "tb_color_bbox_runs", "tb_color_bbox_denoise",
                 "tb_color_full_frame_bbox"):
        fixture = SIM / (name + ".v")
        if not fixture.exists():
            shutil.copyfile(donor_sim / fixture.name, fixture)
        run_case(name)
    print("B_RESCUE_RTL_REGRESSION_PASS")


if __name__ == "__main__":
    main()
