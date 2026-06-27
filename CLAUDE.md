# プロジェクトメモ

## 方針
- **スクリプト言語は Ruby を優先**する。強い事情（Ruby で実現困難／既存が Python 等）がない限り、
  自動化スクリプトやワンショットの処理は Python ではなく Ruby で書くこと。

## 構成
- このリポジトリは `tools.kakipo.com`（GitHub Pages）のツール置き場。各ツールは `<名前>/index.html`。
- 鋳造価格ツール: `yuai2026/`。単価は税込で扱い、合計も税込（消費税の別途加算なし）。
- シルバー地金単価は `scripts/update_prices.rb`（Ruby）が日次取得し保存。ページ起動時に読み込んで反映する。
  - 鋳造相場＝Seaforce SV925/950、一般相場＝田中貴金属 銀（いずれも税込・円/g）。
  - `yuai2026/prices.json`＝最新値、`yuai2026/prices-history.json`＝日次の時系列（チャート用）。
  - チャートは Chart.js（CDN）で2系列を重ねて表示。履歴は導入日から蓄積（過去分なし）。
