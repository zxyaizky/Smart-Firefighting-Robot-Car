"""Coincident SOF/first pixel, gapless frame boundary and pending-mailbox busy."""
import json
from run_tiles import SIM, run, tool
from run_rgb_input import reference


def main():
    dest = SIM/'rgb_input'
    dest.mkdir(exist_ok=True)
    image = reference(31)
    stream = [image[c*19200+(y+15)*160+x]
              for y in range(90) for x in range(160) for c in range(3)]
    (dest/'edge_golden.hex').write_text(''.join(f'{b:02x}\n' for b in stream))
    run([tool('vlog'), '-work', 'sim/work', 'td_project/import/npu_rgb_input.v',
         'sim/tb_rgb_edges.v'], dest/'edge_compile.log')
    out = run([tool('vsim'), '-c', '-lib', 'sim/work', 'tb_rgb_edges',
               '-do', 'run -all; quit -f'], dest/'edge_simulation.log')
    assert 'RGB_EDGES_PASS' in out and 'FAIL' not in out, out[-2000:]
    result = dict(result='PASS', complete_frames=3, bytes_checked=129600,
                  coincident_sof_first_pixel=True, gapless_source_frames=True,
                  bounded_fifo_overflow_recovered=True)
    (dest/'edge_summary.json').write_text(json.dumps(result, indent=2))
    print(json.dumps(result))


if __name__ == '__main__':
    main()
