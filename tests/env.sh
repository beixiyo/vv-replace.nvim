# 实际搜索/替换 fixture 使用调用方已安装的 ripgrep
command -v rg >/dev/null 2>&1 || {
  printf 'Replace integration tests require ripgrep (rg) 13+.\n' >&2
  exit 1
}
