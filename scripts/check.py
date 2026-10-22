"""Checks the built dashboard against the registry and the source files.

Run after scripts/build-dashboard.ps1. Everything it prints is read back out of
docs/index.html - the file that actually ships - rather than from the build's own
log, so a step that silently dropped data shows up here.

    python scripts/check.py
"""
import collections
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OK, BAD = [], []


def check(cond, good, bad):
    (OK if cond else BAD).append(good if cond else bad)


def load_built():
    p = os.path.join(ROOT, 'docs', 'index.html')
    html = open(p, encoding='utf-8').read()
    data = json.loads(re.search(r'const DATA = (\{.*?\});\nconst MY', html, re.S).group(1))
    cards = json.loads(re.search(r'const MY = (\{.*?\});\nconst PROG', html, re.S).group(1))
    progs = json.loads(re.search(r'const PROG = (\{.*?\});\nconst ALL', html, re.S).group(1))
    return html, data, cards, progs


def main():
    html, DATA, CARDS, PROGS = load_built()
    rows = DATA['rows']
    pid = {p['id'] for p in PROGS['programs']}
    used = collections.Counter(r['c'] for r in rows)

    print(f"{len(rows):,} rows · {len(CARDS['cards'])} cards · {len(pid)} programmes · built {DATA['built']}\n")

    # 1. every row names a programme the registry knows
    unknown = {c for c in used if c not in pid}
    check(not unknown, 'every row maps to a known programme', f'rows name unknown programmes: {unknown}')

    # 2. every card's programmes exist, and every card opens something
    for c in CARDS['cards']:
        miss = [p for p in c.get('programs', []) if p not in pid]
        check(not miss, f"{c['name']}: programmes exist", f"{c['name']}: unknown programmes {miss}")
    empty = [c['name'] for c in CARDS['cards']
             if not any(used.get(p) for p in c.get('programs', []))]
    check(not empty, 'every card opens at least one row', f'cards with no rows at all: {empty}')

    # 3. a programme in the registry that produced nothing is a silently broken step
    idle = sorted(p for p in pid if not used.get(p))
    check(not idle, 'every programme produced rows', f'programmes with no rows: {idle}')

    # 4. every row is reachable: it must land in a group, or no screen will show it
    groups = {g['name'] for g in DATA['groups']}
    lost = [r for r in rows if not (set(r.get('gr') or []) & groups)]
    by_prog = collections.Counter(r['c'] for r in lost)
    check(not lost, 'every row lands in a group',
          f'{len(lost):,} rows land in no group: {dict(by_prog)}')

    # 5. geography: a row with a real city should carry coordinates, or it misses the map
    located = [r for r in rows if r.get('w') and r['w'] != 'בכל הארץ']
    geo = [r for r in located if r.get('lat')]
    pct = 100 * len(geo) / max(1, len(located))
    check(pct > 60, f'{pct:.0f}% of city rows are on the map ({len(geo):,}/{len(located):,})',
          f'only {pct:.0f}% of city rows are on the map ({len(geo):,}/{len(located):,})')

    # 6. the discount percentage must be a percentage
    bad_pct = [r for r in rows if not isinstance(r.get('p'), (int, float)) or not 0 <= r['p'] <= 100]
    check(not bad_pct, 'every discount is between 0 and 100',
          f'{len(bad_pct)} rows have an impossible discount, e.g. {[r.get("p") for r in bad_pct[:5]]}')

    # 7. no empty names, and no row without something to show
    noname = [r for r in rows if not (r.get('n') or '').strip()]
    check(not noname, 'every row has a name', f'{len(noname)} rows have no name')

    # 8. the repo is public: nothing from an account may be in the shipped file
    leak = re.findall(r'"(balance|cardNumber|maxAmountToLoad|walletBalance|loadedThisMonth)"', html)
    check(not leak, 'no account fields in the shipped page', f'account fields found: {set(leak)}')

    # 9. the source files the registry points at are all there
    for p in PROGS['programs']:
        f = p.get('data')
        if f:
            check(os.path.exists(os.path.join(ROOT, f)), f"{p['id']}: data file present",
                  f"{p['id']}: missing {f}")

    print('rows per programme:')
    for k, v in used.most_common():
        name = next((p['short'] or p['name'] for p in PROGS['programs'] if p['id'] == k), k)
        print(f'  {v:7,}  {k:18s} {name}')

    print('\nrows per card:')
    for c in CARDS['cards']:
        n = sum(used.get(p, 0) for p in c.get('programs', []))
        print(f"  {n:7,}  {c['name']}")

    print()
    for m in OK:
        print('  ok   ' + m)
    for m in BAD:
        print('  FAIL ' + m)
    print(f'\n{len(OK)} passed, {len(BAD)} failed')
    return 1 if BAD else 0


if __name__ == '__main__':
    sys.exit(main())
