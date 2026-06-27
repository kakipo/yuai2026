# プロジェクトメモ

## 方針
- **スクリプト言語は Ruby を優先**する。強い事情（Ruby で実現困難／既存が Python 等）がない限り、
  自動化スクリプトやワンショットの処理は Python ではなく Ruby で書くこと。

## 構成
- このリポジトリは `tools.kakipo.com`（GitHub Pages）のツール置き場。各ツールは `<名前>/index.html`。
- 鋳造価格ツール: `yuai2026/`。単価は税込で扱い、合計も税込（消費税の別途加算なし）。
- シルバー地金単価は `scripts/update_prices.rb` が Seaforce から日次取得し `yuai2026/prices.json` に保存、
  ページ起動時に読み込んで反映する。
