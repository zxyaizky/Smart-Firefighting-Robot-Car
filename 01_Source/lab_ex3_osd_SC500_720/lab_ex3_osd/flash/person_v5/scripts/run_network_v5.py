"""Production 12-layer RTL plus native-DDR loader/readback simulation, no FPGA build."""
import sys,json
sys.dont_write_bytecode=True
import compiler_person_v5 as comp
import verify_person_v5_helpers as verify

def main():
    verify.command(['vlib','sim/work'],verify.DEST/'network_vlib.log')
    verify.compile_network()
    cases=json.loads((verify.DEST/'python_verification.json').read_text())['cases']
    summaries=[]
    for case in cases:
        name=case['name'];folder=verify.DEST/'vectors'/name
        print('RTL_CASE_START',name,flush=True)
        output=verify.command(['vsim','-c','-voptargs=+acc','-lib','sim/work','tb_person_network',
            '+INPUT=../vectors/'+name+'/input.hex','+OBSERVED=../vectors/'+name+'/observed.txt',
            '-do','run -all; quit -f'],folder/'simulation.log')
        assert 'PERSON_NETWORK_PASS' in output and 'FAIL' not in output,output[-4000:]
        summaries.append(verify.check_network(name))
        comp.write_json(verify.DEST/'rtl_network_verification.json',dict(result='IN_PROGRESS',completed_cases=summaries))
    comp.write_json(verify.DEST/'rtl_network_verification.json',dict(result='PASS',cases=summaries,
        stage_value_comparisons=sum(s['stage_value_comparisons'] for s in summaries),final_byte_comparisons=1800*len(summaries),
        mismatches=0,max_absolute_error=0,ddr='production scheduler/loader/read bridge + behavioral native memory; PHY not simulated'))
    print('ALL_NETWORK_CASES_EXACT_PASS',len(summaries),flush=True)

if __name__=='__main__':main()
