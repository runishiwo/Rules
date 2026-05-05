#!/bin/bash
# ======================================================
# 一键同步 fork 并安全合并令牌（Linux 修复版）
# ======================================================
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
cd "$(dirname "$0")"

# 检查 python3
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}错误：未检测到 python3，请先安装 Python 3${NC}"
    exit 1
fi

BACKUP_DIR="$HOME/cfnb_token_backup_$(date +%Y%m%d_%H%M%S)"
echo -e "${YELLOW}[1/6] 备份当前令牌文件到 $BACKUP_DIR${NC}"
mkdir -p "$BACKUP_DIR"
cp -f config.json "$BACKUP_DIR/config.json" 2>/dev/null || true
cp -f git_sync.sh "$BACKUP_DIR/git_sync.sh" 2>/dev/null || true
cp -f git_sync.ps1 "$BACKUP_DIR/git_sync.ps1" 2>/dev/null || true
cp -f ip.txt "$BACKUP_DIR/ip.txt" 2>/dev/null || true

# 从备份的 git_sync.sh 中提取 GitHub 信息（通过临时 Python 文件，传参避免转义问题）
echo -e "${YELLOW}正在从 git_sync.sh 提取令牌...${NC}"
TMP_PY=$(mktemp /tmp/cfnb_extract.XXXX.py)
cat > "$TMP_PY" << 'PYEOF'
import re, sys
file_path = sys.argv[1]
with open(file_path, encoding='utf-8') as f:
    text = f.read()
token = re.search(r'github_token="(.+?)"', text)
user  = re.search(r'github_username="(.+?)"', text)
repo  = re.search(r'repo_name="(.+?)"', text)
branch= re.search(r'branch="(.+?)"', text)
print(token.group(1) if token else '')
print(user.group(1) if user else '')
print(repo.group(1) if repo else '')
print(branch.group(1) if branch else '')
PYEOF

read -r TOKEN USERNAME REPO BRANCH <<< $(python3 "$TMP_PY" "$BACKUP_DIR/git_sync.sh")
rm -f "$TMP_PY"

if [ -z "$TOKEN" ] || [ "$TOKEN" = "your_github_personal_access_token_here" ]; then
    echo -e "${RED}错误：git_sync.sh 中的 GitHub Token 仍是占位符，请先填写真实令牌${NC}"
    exit 1
fi

# 如果 branch 是占位符，自动探测
if [ -z "$BRANCH" ] || [ "$BRANCH" = "your_branch" ]; then
    echo -e "${YELLOW}分支名为占位符，自动探测...${NC}"
    git remote set-url origin "https://${TOKEN}@github.com/${USERNAME}/${REPO}.git" 2>/dev/null || true
    BRANCH=$(git remote show origin | grep "HEAD branch" | cut -d " " -f5)
    if [ -z "$BRANCH" ]; then
        echo -e "${RED}无法自动探测分支，请在 git_sync.sh 中手动指定 branch=\"main\"${NC}"
        exit 1
    fi
    echo -e "已探测到默认分支：$BRANCH"
fi

echo -e "${YELLOW}[2/6] 设置免认证远程地址${NC}"
git remote set-url origin "https://${TOKEN}@github.com/${USERNAME}/${REPO}.git"

echo -e "${YELLOW}[3/6] 拉取远程并强制对齐${NC}"
git fetch origin "$BRANCH"
git reset --hard "origin/$BRANCH"

echo -e "${YELLOW}[4/6] 注入令牌到 config.json${NC}"
TMP_MERGE=$(mktemp /tmp/cfnb_merge.XXXX.py)
cat > "$TMP_MERGE" << 'PYEOF'
import json, sys
backup_config = sys.argv[1]
current_config = 'config.json'
with open(backup_config) as f:
    backup = json.load(f)
with open(current_config) as f:
    current = json.load(f)
token_fields = [
    "WXPUSHER_APP_TOKEN", "WXPUSHER_UIDS",
    "CF_API_TOKEN", "CF_ZONE_ID", "CF_DNS_RECORD_NAME"
]
for key in token_fields:
    if key in backup and key in current:
        current[key] = backup[key]
with open(current_config, 'w') as f:
    json.dump(current, f, indent=4, ensure_ascii=False)
print("config.json 令牌注入完成")
PYEOF
python3 "$TMP_MERGE" "$BACKUP_DIR/config.json"
rm -f "$TMP_MERGE"

echo -e "${YELLOW}[5/6] 更新 git_sync.sh（含 --allow-unrelated-histories）${NC}"
TMP_SYNC=$(mktemp /tmp/cfnb_sync.XXXX.py)
cat > "$TMP_SYNC" << PYEOF
import re, sys
token, username, repo, branch = sys.argv[1:]

def update_file(filename):
    try:
        with open(filename, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return
    text = re.sub(r'github_token=".*?"', f'github_token="{token}"', text)
    text = re.sub(r'github_username=".*?"', f'github_username="{username}"', text)
    text = re.sub(r'repo_name=".*?"', f'repo_name="{repo}"', text)
    text = re.sub(r'branch=".*?"', f'branch="{branch}"', text)
    if 'allow-unrelated-histories' not in text:
        text = text.replace(
            'git pull origin "$branch"',
            'git pull origin "$branch" --allow-unrelated-histories'
        )
    with open(filename, 'w', encoding='utf-8') as f:
        f.write(text)
    print(f'{filename} 已更新')

update_file('git_sync.sh')
PYEOF
python3 "$TMP_SYNC" "$TOKEN" "$USERNAME" "$REPO" "$BRANCH"
rm -f "$TMP_SYNC"

echo -e "${YELLOW}[6/6] 恢复 ip.txt${NC}"
if [ -f "$BACKUP_DIR/ip.txt" ]; then
    cp -f "$BACKUP_DIR/ip.txt" ip.txt
    echo "ip.txt 已恢复"
fi

echo -e "${GREEN}========================================"
echo -e " ✅ 一键更新完成！"
echo -e "========================================${NC}"
echo -e "备份保留在：$BACKUP_DIR"
echo -e "可运行 python3 main.py 测试"