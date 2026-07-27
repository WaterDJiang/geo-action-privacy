#!/bin/sh
set -eu

download_root="https://waterdjiang.github.io/geo-action-privacy/downloads"
extension_id=""
release_version="0.3.3"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --extension-id)
      extension_id="${2:-}"
      shift 2
      ;;
    --version)
      release_version="${2:-}"
      shift 2
      ;;
    *)
      printf '%s\n' "未知参数：$1" >&2
      exit 2
      ;;
  esac
done

if ! printf '%s' "$extension_id" | grep -Eq '^[a-p]{32}$'; then
  printf '%s\n' "请使用 --extension-id 传入插件帮助页显示的 32 位扩展 ID。" >&2
  exit 2
fi

if ! command -v node >/dev/null 2>&1; then
  printf '%s\n' "未找到 Node.js。请先安装 Node.js 18 或更高版本。" >&2
  exit 3
fi

node_major="$(node -p "Number(process.versions.node.split('.')[0])")"
if [ "$node_major" -lt 18 ]; then
  printf '%s\n' "当前 Node.js 版本过低，需要 Node.js 18 或更高版本。" >&2
  exit 3
fi

node_path="$(command -v node)"
system_name="$(uname -s)"
task_user_home="$(node -p "require('node:os').homedir()")"
temp_directory="$(mktemp -d)"
cleanup() {
  rm -rf "$temp_directory"
}
trap cleanup EXIT INT TERM

if [ -n "${GEO_ACTION_TEST_ROOT:-}" ]; then
  install_directory="$GEO_ACTION_TEST_ROOT/data"
  manifest_directory="$GEO_ACTION_TEST_ROOT/native-hosts"
  binary_directory="$GEO_ACTION_TEST_ROOT/bin"
  codex_skill_root="$GEO_ACTION_TEST_ROOT/codex-skills"
  claude_skill_root="$GEO_ACTION_TEST_ROOT/claude-skills"
elif [ "$system_name" = "Darwin" ]; then
  install_directory="$task_user_home/Library/Application Support/GEO Action"
  manifest_directory="$task_user_home/Library/Application Support/Google/Chrome/NativeMessagingHosts"
  binary_directory="$task_user_home/.local/bin"
  codex_skill_root="$task_user_home/.codex/skills"
  claude_skill_root="$task_user_home/.claude/skills"
else
  data_root="${XDG_DATA_HOME:-$task_user_home/.local/share}"
  config_root="${XDG_CONFIG_HOME:-$task_user_home/.config}"
  install_directory="$data_root/geo-action"
  manifest_directory="$config_root/google-chrome/NativeMessagingHosts"
  binary_directory="$task_user_home/.local/bin"
  codex_skill_root="$task_user_home/.codex/skills"
  claude_skill_root="$task_user_home/.claude/skills"
fi

if [ -n "${GEO_ACTION_PAYLOAD_DIR:-}" ]; then
  payload_root="$GEO_ACTION_PAYLOAD_DIR"
else
  if [ "$release_version" = "latest" ]; then
    release_base="$download_root/latest"
  else
    release_base="$download_root/v$release_version"
  fi
  archive_path="$temp_directory/geo-action-cli.tar.gz"
  checksums_path="$temp_directory/checksums.txt"
  curl -fL --retry 3 "$release_base/geo-action-cli.tar.gz" -o "$archive_path"
  curl -fL --retry 3 "$release_base/checksums.txt" -o "$checksums_path"
  expected_hash="$(awk '$2 == "geo-action-cli.tar.gz" { print $1 }' "$checksums_path")"
  if [ -z "$expected_hash" ]; then
    printf '%s\n' "校验文件缺少 geo-action-cli.tar.gz。" >&2
    exit 4
  fi
  if command -v shasum >/dev/null 2>&1; then
    actual_hash="$(shasum -a 256 "$archive_path" | awk '{print $1}')"
  else
    actual_hash="$(sha256sum "$archive_path" | awk '{print $1}')"
  fi
  if [ "$expected_hash" != "$actual_hash" ]; then
    printf '%s\n' "CLI 安装包 SHA-256 校验失败。" >&2
    exit 4
  fi
  tar -xzf "$archive_path" -C "$temp_directory"
  payload_root="$temp_directory/geo-action-cli"
fi

if [ ! -f "$payload_root/native-host/host.mjs" ] ||
  [ ! -f "$payload_root/native-host/cli.mjs" ] ||
  [ ! -f "$payload_root/skills/geo-action/SKILL.md" ]; then
  printf '%s\n' "CLI 安装包结构不完整。" >&2
  exit 4
fi

mkdir -p "$install_directory" "$binary_directory" "$manifest_directory"
chmod 700 "$install_directory"
cp -R "$payload_root/native-host/." "$install_directory/"
mkdir -p "$install_directory/skills"
rm -rf "$install_directory/skills/geo-action"
cp -R "$payload_root/skills/geo-action" "$install_directory/skills/geo-action"

node - "$install_directory/config.json" "$extension_id" <<'NODE'
const fs = require('node:fs')
const [file, extensionId] = process.argv.slice(2)
fs.writeFileSync(file, `${JSON.stringify({
  extensionId,
  installedAt: new Date().toISOString(),
  version: '0.3.3',
}, null, 2)}\n`, { mode: 0o600 })
NODE

if [ ! -f "$install_directory/bridge-token" ]; then
  node - "$install_directory/bridge-token" <<'NODE'
const fs = require('node:fs')
const crypto = require('node:crypto')
fs.writeFileSync(process.argv[2], `${crypto.randomBytes(32).toString('hex')}\n`, { mode: 0o600 })
NODE
fi
chmod 600 "$install_directory/config.json" "$install_directory/bridge-token"

launcher_path="$install_directory/native-host-launcher.sh"
node - "$launcher_path" "$node_path" "$install_directory/host.mjs" <<'NODE'
const fs = require('node:fs')
const [file, nodePath, hostPath] = process.argv.slice(2)
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`
fs.writeFileSync(file, `#!/bin/sh\nexec ${quote(nodePath)} ${quote(hostPath)} "$@"\n`, { mode: 0o700 })
NODE
chmod 700 "$launcher_path"

node - "$manifest_directory/cn.wattter.geo_action.json" "$launcher_path" "$extension_id" <<'NODE'
const fs = require('node:fs')
const [file, launcherPath, extensionId] = process.argv.slice(2)
fs.writeFileSync(file, `${JSON.stringify({
  name: 'cn.wattter.geo_action',
  description: 'GEO Action local AI and CLI bridge',
  path: launcherPath,
  type: 'stdio',
  allowed_origins: [`chrome-extension://${extensionId}/`],
}, null, 2)}\n`)
NODE

cli_path="$binary_directory/geo-action"
node - "$cli_path" "$node_path" "$install_directory/cli.mjs" <<'NODE'
const fs = require('node:fs')
const [file, nodePath, cliPath] = process.argv.slice(2)
const quote = (value) => `'${value.replaceAll("'", "'\\''")}'`
fs.writeFileSync(file, `#!/bin/sh\nexec ${quote(nodePath)} ${quote(cliPath)} "$@"\n`, { mode: 0o700 })
NODE
chmod 700 "$cli_path"

for skill_root in "$codex_skill_root" "$claude_skill_root"; do
  mkdir -p "$skill_root"
  rm -rf "$skill_root/geo-action"
  cp -R "$install_directory/skills/geo-action" "$skill_root/geo-action"
done

printf '%s\n' "GEO Action CLI 0.3.3 安装完成。"
printf '%s\n' "CLI：$cli_path"
printf '%s\n' "下一步："
printf '%s\n' "1. 保持 Chrome 与 GEO Action 启用，在插件“CLI 与本地 AI”页点击“重新连接 CLI”。"
printf '%s\n' "2. 重新打开 AI 工具会话；无需手动启动 daemon。"
printf '%s\n' '3. Codex 输入：$geo-action 请把 /绝对路径/article.md 准备为微信公众号和知乎草稿'
printf '%s\n' '4. Claude Code 输入：/geo-action 请把 /绝对路径/article.md 准备为微信公众号和知乎草稿'
printf '%s\n' "5. 直接使用 CLI 时先运行："
printf '%s\n' "$cli_path doctor"
case ":${PATH:-}:" in
  *":$binary_directory:"*) ;;
  *)
    printf '%s\n' "提示：$binary_directory 尚未加入 PATH，可先使用上面的完整路径。"
    ;;
esac
