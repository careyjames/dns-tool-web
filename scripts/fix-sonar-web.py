#!/usr/bin/env python3
"""Rewrite sonar-project.properties for the dns-tool-web public mirror."""
import sys, re

path = sys.argv[1]
with open(path) as f:
    content = f.read()

content = content.replace('sonar.projectKey=dns-tool-full', 'sonar.projectKey=dns-tool-web')
content = re.sub(
    r'sonar\.projectName=.*',
    'sonar.projectName=DNS Tool \xb7 Public Mirror (dns-tool-web)',
    content,
)

intel_patterns = [
    '_intel.go',
    'go-server/cmd/probe/',
    'go-server/internal/handlers/admin_probes',
]
lines = content.split('\n')
filtered = []
i = 0
while i < len(lines):
    line = lines[i]
    if re.match(r'^sonar\.issue\.ignore\.multicriteria\.\w+\.ruleKey=', line):
        resource_line = lines[i + 1] if i + 1 < len(lines) else ''
        if any(p in resource_line for p in intel_patterns):
            while len(filtered) > 0 and filtered[-1].startswith('#'):
                filtered.pop()
            i += 2
            while i < len(lines) and lines[i] == '':
                i += 1
            continue
    filtered.append(line)
    i += 1

content = '\n'.join(filtered)
mc = re.search(r'^sonar\.issue\.ignore\.multicriteria=(.*)', content, re.MULTILINE)
if mc:
    keys = [k for k in mc.group(1).split(',') if f'multicriteria.{k}.ruleKey=' in content]
    content = content.replace(mc.group(0), f'sonar.issue.ignore.multicriteria={",".join(keys)}')

content = re.sub(
    r'(sonar\.cpd\.exclusions=)(.*)',
    lambda m: m.group(1) + ','.join(p for p in m.group(2).split(',') if '_intel.go' not in p)
    if any(p for p in m.group(2).split(',') if '_intel.go' not in p)
    else '',
    content,
)
content = re.sub(
    r'sonar\.coverage\.exclusions=(.*)$',
    lambda m: 'sonar.coverage.exclusions=' + ','.join(
        p for p in m.group(1).split(',') if 'probe' not in p.lower()
    ),
    content,
    flags=re.MULTILINE,
)
content = re.sub(r'\n{3,}', '\n\n', content)
with open(path, 'w') as f:
    f.write(content)
print(f'Patched {path}')
