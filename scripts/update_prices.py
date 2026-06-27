#!/usr/bin/env python3
"""Seaforce(加工net) の鋳造料金ページから本日のシルバー地金単価(税込)を取得し、
yuai2026/prices.json を更新する。GitHub Actions から日次で実行する想定。

取得・解析に失敗した場合は既存の prices.json を維持し、終了コード0で抜ける
（=デプロイは継続し、サイトは前回値で動作する）。
"""
import datetime
import json
import pathlib
import re
import sys
import urllib.request

URL = "https://www.kakounet.com/cast/cast/price.html"
OUT = pathlib.Path(__file__).resolve().parent.parent / "yuai2026" / "prices.json"
UA = "Mozilla/5.0 (compatible; tools.kakipo.com price-bot; +https://tools.kakipo.com/yuai2026/)"


def fetch_html(url: str) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(req, timeout=30) as res:
        return res.read().decode("utf-8", "replace")


def parse_silver_price(html: str) -> int:
    # 例: <span class=" d-largest_font">SV925/950&nbsp; &nbsp; ￥476</span>
    m = re.search(r"SV925/950[^￥]*￥\s*([\d,]+)", html)
    if not m:
        raise ValueError("SV925/950 の地金価格が見つかりません")
    return int(m.group(1).replace(",", ""))


def parse_source_date(html: str) -> str:
    # 例: 本日の地金価格(税込)　　2026/6/26(金)更新
    m = re.search(r"本日の地金価格[^0-9]*(\d{4}/\d{1,2}/\d{1,2})", html)
    return m.group(1) if m else ""


def main() -> int:
    try:
        html = fetch_html(URL)
        silver = parse_silver_price(html)
        updated = parse_source_date(html)
    except Exception as e:  # noqa: BLE001
        print(f"WARN: 価格取得に失敗したため既存値を維持します: {e}", file=sys.stderr)
        return 0

    data = {
        "source": URL,
        "note": "地金単価は税込・目安。実際の請求は仕上がり時の相場によります。",
        "sourceUpdated": updated,
        "fetchedAt": datetime.date.today().isoformat(),
        "metals": {"silver": {"metal": silver}},
    }
    OUT.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"OK: silver={silver} (税込) sourceUpdated={updated}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
