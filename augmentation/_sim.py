data = {
    'safe':         {'before': 249, 'aug': 996},
    'acl':          {'before': 150, 'aug': 600},
    'arith':        {'before': 150, 'aug': 600},
    'cb':           {'before': 150, 'aug': 600},
    'acl+arith':    {'before': 100, 'aug': 400},
    'acl+cb':       {'before': 100, 'aug': 400},
    'acl+arith+cb': {'before': 72,  'aug': 288},
    'arith+cb':     {'before': 50,  'aug': 200},
}
total_after = sum(d['before']+d['aug'] for d in data.values())
print("POST-AUGMENTATION DISTRIBUTION (estimated)")
print(f"  {'Category':<22} {'Before':>6}  {'Aug':>6} {'After':>7}  {'%':>5}")
print("  " + "-"*50)
for cat, d in sorted(data.items(), key=lambda x: -(x[1]['before']+x[1]['aug'])):
    after = d['before'] + d['aug']
    print(f"  {cat:<22} {d['before']:>6}  {d['aug']:>6} {after:>7}  {after/total_after*100:5.1f}%")
print("  " + "-"*50)
print(f"  {'TOTAL':<22} {sum(d['before'] for d in data.values()):>6}  {sum(d['aug'] for d in data.values()):>6} {total_after:>7}  100.0%")
