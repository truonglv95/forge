import json, time, urllib.request
import sys
sys.path.insert(0, '/home/z/my-project/scripts')
from forge_provider_benchmark import zai_chat, TEST_PROMPTS, TOOL_TEST, run_test, run_tool_test

# Only test 4 models, with 8s sleep between EACH call to stay under rate limit
models = ['glm-4-plus', 'glm-4.5', 'glm-4.6', 'glm-4-flash']
results = []

for model in models:
    print(f'--- {model} ---', flush=True)
    for test_name, test_def in TEST_PROMPTS.items():
        r = run_test('zai', model, test_name, test_def)
        results.append(r)
        status = 'PASS' if r['success'] else 'FAIL'
        tok = r.get('tokens_total') or 0
        err = r.get('error', '')
        print(f'  {test_name:14s} {status:5s} {r["elapsed_s"]:.2f}s {tok}tok {err}', flush=True)
        # If we got rate-limited, wait longer
        if '429' in str(err):
            print('  rate-limited, sleeping 30s...', flush=True)
            time.sleep(30)
        else:
            time.sleep(8)
    r = run_tool_test('zai', model)
    results.append(r)
    status = 'PASS' if r['success'] else 'FAIL'
    tok = r.get('tokens_total') or 0
    called = r.get('called_tool', '')
    err = r.get('error', '')
    print(f'  tool_call      {status:5s} {r["elapsed_s"]:.2f}s {tok}tok called={called} {err}', flush=True)
    if '429' in str(err):
        print('  rate-limited, sleeping 30s...', flush=True)
        time.sleep(30)
    else:
        time.sleep(8)

with open('/home/z/my-project/download/free_llm_test/benchmark_results.json', 'w') as f:
    json.dump(results, f, indent=2)
print(f'\nSaved {len(results)} results', flush=True)
