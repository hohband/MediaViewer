#!/usr/bin/env bash
# 跑完仓库里的全部自动验证：元数据链路 + 界面冒烟 + Finder 处理程序。
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/verify-metadata.sh

echo
echo "############################################################"
echo

./scripts/ui-smoke.sh

echo
echo "############################################################"
echo

./scripts/verify-handler.sh
