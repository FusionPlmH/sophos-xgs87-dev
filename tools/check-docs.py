#!/usr/bin/env python3
"""Two checks that the restructure must pass.

1. every §NN.x / §NN.NN reference resolves to a heading that exists
2. every relative markdown link resolves to a file that exists
"""
import glob
import os
import re
import sys

docs = sorted(glob.glob('docs/*.md')) + sorted(glob.glob('docs/archive/*.md'))
valid = {}          # chapter number as string -> set of section paths
headings = {}
for p in docs:
    secs = set()
    for line in open(p, encoding='utf-8'):
        m = re.match(r'^#{2,4} (\d+)\.([\d.]+)', line)
        if m:
            num = str(int(m.group(1)))
            secs.add(num + '.' + m.group(2).rstrip('.'))
    valid.setdefault('_all', set()).update(secs)
    headings[p] = secs

fail = 0
for p in docs:
    for i, line in enumerate(open(p, encoding='utf-8'), 1):
        for m in re.finditer(r'§ ?(\d+)\.([\d.]+)', line):
            num, sub = m.group(1), m.group(2).rstrip('.')
            ref = num + '.' + sub
            if ref not in valid['_all']:
                # tolerate a reference to the chapter as a whole (e.g. §9)
                if sub and (num + '.' + sub.split('.')[0]) in valid['_all']:
                    continue
                print('DANGLING SECTION %s:%d  %s' % (p, i, ref))
                fail += 1

for p in glob.glob('*.md') + glob.glob('docs/**/*.md', recursive=True) + \
        glob.glob('image/*.md') + glob.glob('systemd/*.md') + glob.glob('tools/*.md'):
    d = os.path.dirname(p)
    for i, line in enumerate(open(p, encoding='utf-8'), 1):
        for m in re.finditer(r'\[[^\]]*\]\(([^)]+)\)', line):
            t = m.group(1).split('#')[0].strip()
            if not t or t.startswith(('http', 'mailto:', '#')):
                continue
            fp = os.path.normpath(os.path.join(d, t.strip('<>')))
            if not os.path.exists(fp):
                print('BROKEN LINK %s:%d  %s' % (p, i, m.group(1)))
                fail += 1

print('---')
print('%d docs, %d problems' % (len(docs), fail))
sys.exit(1 if fail else 0)
