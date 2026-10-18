#!/bin/bash
# OpenCode 部分的部署：在 ~/.config/opencode/plugins/ 生成转发文件
# coding_agents_env.ts，内容只有一行 export，指向仓库里的 opencode/notify.ts
# （不拷贝代码，git pull 即生效；不用软链——Windows 下 Git Bash 的 ln -s 是复制）。
# 只写自己这一个文件，plugins/ 目录里其他插件一律不动。

set -euo pipefail

# dirname only splits on /. Git Bash started from Windows may see D:\...\script.sh.
_self=${0//\\//}
REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$_self")/.." && pwd)}"
OC_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
PLUGIN_DIR="$OC_DIR/plugins"
STUB="$PLUGIN_DIR/coding_agents_env.ts"

target="$REPO_DIR/opencode/notify.ts"
case "$(uname)" in
  MINGW*|MSYS*|CYGWIN*) target=$(cygpath -m "$target") ;;   # C:/Users/... 形式，Bun 认
esac

mkdir -p "$PLUGIN_DIR"
cat > "$STUB" <<STUBEOF
// 由 coding_agents_env/install.sh 生成，不要手改；真正的代码在仓库里：
// $target
export { default } from "$target"
STUBEOF

echo "✅ OpenCode"
echo "   通知插件 → $STUB"
echo "              → $target"
