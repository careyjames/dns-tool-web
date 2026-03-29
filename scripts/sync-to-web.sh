#!/bin/bash
# OSS mirror sync — push filtered files to dns-tool-web via native git + PR.
# Usage: bash scripts/sync-to-web.sh
#
# Shallow-clones dns-tool-web, replaces all files with filtered local copy
# (proprietary files excluded), commits, pushes to a sync branch, and
# auto-merges via PR. Works reliably regardless of file count.
#
# Uses GH_SYNC_TOKEN (or ORG_PAT / GITHUB_MASTER_PAT fallback) for authentication.

set -euo pipefail
cd "$(dirname "$0")/.."

REPO_OWNER="IT-Help-San-Diego"
REPO_NAME="dns-tool-web"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${YELLOW}▸${NC} $1"; }

TOKEN="${GH_SYNC_TOKEN:-${ORG_PAT:-${GITHUB_MASTER_PAT:-}}}"
if [ -z "$TOKEN" ]; then
  fail "GH_SYNC_TOKEN (or ORG_PAT) not set. Cannot authenticate with GitHub."
fi

VERSION=$(grep 'Version.*=' go-server/internal/config/config.go | head -1 | sed 's/.*"\(.*\)".*/\1/')
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  OSS Sync → ${REPO_OWNER}/${REPO_NAME}/main"
echo "  App version: v${VERSION}"
echo "  Proprietary files will be EXCLUDED"
echo "═══════════════════════════════════════════════════════"
echo ""

if ! git diff-index --quiet HEAD -- 2>/dev/null; then
  info "Working tree has uncommitted changes — syncing from filesystem (API push was used)"
fi
pass "Working tree OK"

LOCAL_MSG=$(git log -1 --format='%s' 2>/dev/null)
pass "Last commit: ${LOCAL_MSG}"

info "Syncing to ${REPO_NAME} (public OSS repo — proprietary code stripped)"

RESULT=$(python3 << 'PYEOF'
import os, sys, json, urllib.request, subprocess, shutil, time

src_dir = os.getcwd()
clone_dir = "/tmp/dns-tool-web-sync"
token = os.environ.get('GH_SYNC_TOKEN') or os.environ.get('ORG_PAT') or os.environ.get('GITHUB_MASTER_PAT', '')
repo_slug = "IT-Help-San-Diego/dns-tool-web"
repo_url = f"https://x-access-token:{token}@github.com/{repo_slug}.git"
headers = {
    'Authorization': f'Bearer {token}',
    'Accept': 'application/vnd.github.v3+json',
    'Content-Type': 'application/json'
}

EXCLUDE_DIRS = {
    '.local', '.agents',
    'attached_assets', 'node_modules', '.git', '.cache', '.config',
    '.upm', '__pycache__', '.replit.nix', '.pythonlibs',
    'premium_templates', 'generated', 'premium_docs',
    '.generated', '.replit-artifact', 'artifacts',
    'logs'
}
EXCLUDE_FILES = {
    '.replit', 'replit.nix', '.replit.nix', 'replit_agent.toml',
    'poetry.lock', 'pyproject.toml', '.breakpoints', '.gitattributes',
    'dns-tool-server', 'Makefile.proprietary', '.env',
    'main.py', 'models.py', 'app.py',
    '.cursorignore', '.cursorindexingignore', '.cursorrules',
    'PROPRIETARY.md'
}
EXCLUDE_PREFIXES = (
    '.local/', '.agents/', 'attached_assets/',
    'premium_', 'generated/',
    'artifacts/', 'stubs/',
    '.github/workflows/',
    'providers/', 'ai_surface/',
    'commands/', 'golden_rules/', 'remediation/', 'scoring/'
)

PUBLIC_EXCLUDES = set()
_pe_path = os.path.join(src_dir, 'scripts', 'public-excludes.txt')
if os.path.isfile(_pe_path):
    with open(_pe_path) as _pf:
        for _line in _pf:
            _line = _line.strip()
            if _line and not _line.startswith('#'):
                PUBLIC_EXCLUDES.add(_line)
    print(f"  Loaded {len(PUBLIC_EXCLUDES)} path(s) from public-excludes.txt", file=sys.stderr)
else:
    print(f"  WARNING: public-excludes.txt not found at {_pe_path}", file=sys.stderr)

def is_excluded(path):
    if path in PUBLIC_EXCLUDES:
        return True
    parts = path.split('/')
    for p in parts:
        if p in EXCLUDE_DIRS:
            return True
    if os.path.basename(path) in EXCLUDE_FILES:
        return True
    for prefix in EXCLUDE_PREFIXES:
        if path.startswith(prefix):
            return True
    return False

def has_intel_build_tag(filepath):
    try:
        with open(filepath, 'r', errors='ignore') as f:
            for line in f:
                if line.startswith('//go:build'):
                    tag = line.strip()
                    if 'intel' in tag and '!intel' not in tag:
                        return True
                    return False
                if line.strip() and not line.startswith('//') and not line.startswith('package'):
                    break
    except:
        pass
    return False

def api(method, url, data=None):
    body = json.dumps(data).encode() if data else None
    for attempt in range(3):
        try:
            req = urllib.request.Request(f'https://api.github.com{url}',
                data=body, headers=headers, method=method)
            return json.loads(urllib.request.urlopen(req).read())
        except urllib.error.HTTPError as e:
            err_body = ''
            try:
                err_body = e.read().decode('utf-8', errors='replace')
            except:
                pass
            print(f"  HTTP {e.code} {method} {url}: {err_body[:500]}", file=sys.stderr)
            if e.code in (403, 429) and attempt < 2:
                time.sleep(5 * (attempt + 1))
            elif e.code == 422 and 'already exists' in err_body.lower():
                print(f"  (PR already exists — attempting to find and merge)", file=sys.stderr)
                return json.loads(err_body) if err_body.startswith('{') else {'errors': err_body}
            else:
                raise

eligible = []
for root, dirs, files in os.walk(src_dir):
    dirs[:] = [d for d in dirs if d not in EXCLUDE_DIRS and not d.startswith('.')]
    for f in files:
        full = os.path.join(root, f)
        rel = os.path.relpath(full, src_dir)
        if is_excluded(rel):
            continue
        if rel.endswith('.go') and has_intel_build_tag(full):
            continue
        eligible.append(rel)

print(f"ELIGIBLE {len(eligible)} files", file=sys.stderr)

if os.path.exists(clone_dir):
    shutil.rmtree(clone_dir)

subprocess.run(
    ['git', 'clone', '--depth', '1', '--single-branch', '--branch', 'main', repo_url, clone_dir],
    capture_output=True, text=True, timeout=120, check=True
)

for item in os.listdir(clone_dir):
    if item == '.git':
        continue
    path = os.path.join(clone_dir, item)
    if os.path.isdir(path):
        shutil.rmtree(path)
    else:
        os.remove(path)

for rel in eligible:
    src = os.path.join(src_dir, rel)
    dst = os.path.join(clone_dir, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copy2(src, dst)

sonar_props = os.path.join(clone_dir, 'sonar-project.properties')
if os.path.exists(sonar_props):
    with open(sonar_props, 'r') as f:
        content = f.read()
    content = content.replace('sonar.projectKey=dns-tool-full', 'sonar.projectKey=dns-tool-web')
    import re
    content = re.sub(r'sonar\.projectName=.*', 'sonar.projectName=DNS Tool · Public Mirror (dns-tool-web)', content)
    INTEL_ONLY_PATTERNS = [
        '_intel.go',
        'go-server/cmd/probe/',
        'go-server/internal/handlers/admin_probes',
    ]
    def is_intel_only_rule(block):
        for pat in INTEL_ONLY_PATTERNS:
            if pat in block:
                return True
        return False
    lines = content.split('\n')
    filtered = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r'^sonar\.issue\.ignore\.multicriteria\.\w+\.ruleKey=', line):
            resource_line = lines[i + 1] if i + 1 < len(lines) else ''
            if is_intel_only_rule(resource_line):
                comment_start = len(filtered) - 1
                while comment_start >= 0 and filtered[comment_start].startswith('#'):
                    comment_start -= 1
                filtered = filtered[:comment_start + 1]
                i += 2
                while i < len(lines) and lines[i] == '':
                    i += 1
                continue
            else:
                filtered.append(line)
                i += 1
        else:
            filtered.append(line)
            i += 1
    content = '\n'.join(filtered)
    multicriteria_match = re.search(r'^sonar\.issue\.ignore\.multicriteria=(.*)', content, re.MULTILINE)
    if multicriteria_match:
        keys = multicriteria_match.group(1).split(',')
        remaining_keys = [k for k in keys if f'multicriteria.{k}.ruleKey=' in content]
        content = content.replace(multicriteria_match.group(0),
            f'sonar.issue.ignore.multicriteria={",".join(remaining_keys)}')
    content = re.sub(r'(sonar\.cpd\.exclusions=)(.*)', lambda m: m.group(1) + ','.join(
        p for p in m.group(2).split(',') if '_intel.go' not in p
    ) if any(p for p in m.group(2).split(',') if '_intel.go' not in p) else '', content)
    content = re.sub(r'sonar\.coverage\.exclusions=(.*)$',
        lambda m: 'sonar.coverage.exclusions=' + ','.join(
            p for p in m.group(1).split(',')
            if 'probe' not in p.lower()
        ), content, flags=re.MULTILINE)
    content = re.sub(r'\n{3,}', '\n\n', content)
    with open(sonar_props, 'w') as f:
        f.write(content)
    if 'dns-tool-web' in content and 'dns-tool-full' not in content:
        print("  sonar-project.properties: key/name rewritten for dns-tool-web", file=sys.stderr)
    else:
        print("  WARNING: sonar rewrite may have failed", file=sys.stderr)

web_wf_src = os.path.join(src_dir, '.github', 'workflows-web')
web_wf_dst = os.path.join(clone_dir, '.github', 'workflows')
if os.path.isdir(web_wf_src):
    os.makedirs(web_wf_dst, exist_ok=True)
    for wf in os.listdir(web_wf_src):
        shutil.copy2(os.path.join(web_wf_src, wf), os.path.join(web_wf_dst, wf))
    print(f"  Copied {len(os.listdir(web_wf_src))} web workflow(s) to .github/workflows/", file=sys.stderr)

subprocess.run(['git', 'config', 'user.email', 'research@it-help.tech'], cwd=clone_dir, check=True)
subprocess.run(['git', 'config', 'user.name', 'IT Help San Diego'], cwd=clone_dir, check=True)
subprocess.run(['git', 'add', '-A'], cwd=clone_dir, check=True, capture_output=True)

status = subprocess.run(['git', 'status', '--porcelain'], cwd=clone_dir, capture_output=True, text=True)
changes = [l for l in status.stdout.strip().split('\n') if l.strip()]

if not changes:
    print("UP_TO_DATE")
    sys.exit(0)

version_line = subprocess.run(
    ['grep', 'Version.*=', 'go-server/internal/config/config.go'],
    capture_output=True, text=True, cwd=src_dir
).stdout.strip()
version = version_line.split('"')[1] if '"' in version_line else 'unknown'

last_msg = subprocess.run(['git', 'log', '-1', '--format=%s'], capture_output=True, text=True, cwd=src_dir).stdout.strip()
branch_name = f"sync/v{version}"
commit_msg = f"v{version}: {last_msg}\n\n{len(changes)} files synced from dns-tool-intel (proprietary excluded)"

subprocess.run(['git', 'commit', '-m', commit_msg], cwd=clone_dir, check=True, capture_output=True)
subprocess.run(['git', 'push', 'origin', f'HEAD:{branch_name}', '--force'],
    cwd=clone_dir, check=True, capture_output=True, timeout=300)

sha = subprocess.run(['git', 'rev-parse', 'HEAD'], cwd=clone_dir, capture_output=True, text=True).stdout.strip()
print(f"  pushed {sha[:12]} to {branch_name}", file=sys.stderr)

pr = api('POST', f'/repos/{repo_slug}/pulls', {
    'title': f'v{version}: {last_msg}',
    'body': f'{len(changes)} files synced from dns-tool-intel.\nProprietary files excluded.\nAutomated sync via Replit.',
    'head': branch_name,
    'base': 'main'
})
pr_number = pr.get('number')
if not pr_number:
    prs = api('GET', f'/repos/{repo_slug}/pulls?head={repo_slug.split("/")[0]}:{branch_name}&state=open')
    if prs:
        pr_number = prs[0]['number']
        print(f"  Found existing PR #{pr_number}", file=sys.stderr)
    else:
        print(f"  ERROR: Could not create or find PR. Response: {pr}", file=sys.stderr)
        sys.exit(1)
else:
    print(f"  PR #{pr_number} created", file=sys.stderr)

time.sleep(2)

try:
    merge = api('PUT', f'/repos/{repo_slug}/pulls/{pr_number}/merge', {
        'merge_method': 'squash',
        'commit_title': f'v{version}: {last_msg}',
        'commit_message': f'{len(changes)} files synced from dns-tool-intel (proprietary excluded)'
    })
    merge_sha = merge.get('sha', '')[:12]
    print(f"  PR #{pr_number} merged → {merge_sha}", file=sys.stderr)
except Exception as ex:
    print(f"  auto-merge failed: {ex}. Merge manually.", file=sys.stderr)
    merge_sha = sha[:12]

try:
    api('DELETE', f'/repos/{repo_slug}/git/refs/heads/{branch_name}')
except:
    pass

shutil.rmtree(clone_dir, ignore_errors=True)
print(f"PUSHED {len(changes)} {merge_sha}")
PYEOF
) || fail "Sync failed"

if [ "$RESULT" = "UP_TO_DATE" ]; then
  pass "Already up to date — nothing to push"
  echo ""
  echo "All good. Nothing to do."
  exit 0
fi

COMMIT_SHA=$(echo "$RESULT" | grep "^PUSHED" | awk '{print $3}')
FILE_COUNT=$(echo "$RESULT" | grep "^PUSHED" | awk '{print $2}')
pass "Synced ${FILE_COUNT} file(s) → ${REPO_OWNER}/${REPO_NAME}/main (${COMMIT_SHA})"

echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  ${GREEN}Done.${NC} v${VERSION} synced to ${REPO_NAME}/main."
echo "  Proprietary code excluded. Public repo is clean."
echo "═══════════════════════════════════════════════════════"
echo ""
