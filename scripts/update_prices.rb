#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

# 銀地金の価格を2系列取得して保存する（GitHub Actions から日次実行）。
#   - 鋳造相場: Seaforce(加工net) SV925/950 地金単価（税込・円/g）
#   - 一般相場: 田中貴金属 銀 店頭小売価格（税込・円/g）
#
# 出力:
#   - yuai2026/prices.json         … 最新スナップショット（ページの地金単価反映に使用）
#   - yuai2026/prices-history.json … 日次の時系列（チャート用、当日分を upsert）
#
# どちらかの取得・解析に失敗しても、前回値で補完して可能な範囲で更新し、
# 終了コード0で抜ける（デプロイ継続・サイトは前回値で動作）。

require "net/http"
require "uri"
require "json"
require "date"

SEAFORCE_URL = "https://www.kakounet.com/cast/cast/price.html"
TANAKA_URL   = "https://gold.tanaka.co.jp/commodity/souba/"

PRICES  = File.expand_path("../yuai2026/prices.json", __dir__)
HISTORY = File.expand_path("../yuai2026/prices-history.json", __dir__)
UA = "Mozilla/5.0 (compatible; tools.kakipo.com price-bot; +https://tools.kakipo.com/yuai2026/)"

def fetch_html(url)
  uri = URI.parse(url)
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = (uri.scheme == "https")
  http.open_timeout = 30
  http.read_timeout = 30
  res = http.get(uri.request_uri, "User-Agent" => UA)
  raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

  res.body.force_encoding("UTF-8")
end

# --- Seaforce（鋳造相場） ---------------------------------------------------
# 例: <span class=" d-largest_font">SV925/950&nbsp; &nbsp; ￥476</span>
def parse_casting_silver(html)
  m = html.match(%r{SV925/950[^￥]*￥\s*([\d,]+)})
  raise "Seaforce: SV925/950 の地金価格が見つかりません" unless m

  m[1].delete(",").to_i
end

# 例: 本日の地金価格(税込)　　2026/6/26(金)更新
def parse_casting_date(html)
  m = html.match(%r{本日の地金価格[^0-9]*(\d{4}/\d{1,2}/\d{1,2})})
  m ? m[1] : ""
end

# --- 田中貴金属（一般相場） -------------------------------------------------
# 例: <tr class="silver">...<td class="retail_tax">352.22 円</td>
def parse_market_silver(html)
  m = html.match(%r{class="silver".*?<td class="retail_tax">\s*([\d,]+(?:\.\d+)?)\s*円}m)
  raise "Tanaka: 銀の店頭小売価格が見つかりません" unless m

  m[1].delete(",").to_f
end

# 例: <h3>地金価格<span>2026年06月26日 17:00公表（日本時間）</span></h3>
def parse_market_date(html)
  m = html.match(%r{地金価格<span>(\d{4})年(\d{2})月(\d{2})日})
  m ? "#{m[1]}/#{m[2].to_i}/#{m[3].to_i}" : ""
end

# --- 入出力ヘルパ -----------------------------------------------------------
def load_json(path, fallback)
  return fallback unless File.exist?(path)

  JSON.parse(File.read(path))
rescue StandardError
  fallback
end

def upsert_history(history, date, casting, market)
  entry = history.find { |e| e["date"] == date }
  unless entry
    entry = { "date" => date }
    history << entry
  end
  entry["casting"] = casting unless casting.nil?
  entry["market"]  = market  unless market.nil?
  history.sort_by! { |e| e["date"] }
  history
end

def try_fetch(label)
  yield
rescue StandardError => e
  warn "WARN: #{label} の取得に失敗（前回値で補完）: #{e}"
  nil
end

def main
  prev = load_json(PRICES, {})
  prev_casting = prev.dig("metals", "silver", "metal")
  prev_market  = prev.dig("market", "silver")

  casting = casting_date = nil
  if (html = try_fetch("Seaforce") { fetch_html(SEAFORCE_URL) })
    casting      = try_fetch("Seaforce parse") { parse_casting_silver(html) }
    casting_date = parse_casting_date(html) rescue ""
  end

  market = market_date = nil
  if (html = try_fetch("Tanaka") { fetch_html(TANAKA_URL) })
    market      = try_fetch("Tanaka parse") { parse_market_silver(html) }
    market_date = parse_market_date(html) rescue ""
  end

  casting ||= prev_casting
  market  ||= prev_market

  if casting.nil? && market.nil?
    warn "WARN: 両系列とも取得できず、ファイルを更新しません"
    return 0
  end

  today = Date.today.to_s

  prices = {
    "source"        => SEAFORCE_URL,
    "note"          => "地金単価は税込・目安。実際の請求は仕上がり時の相場によります。",
    "sourceUpdated" => (casting_date && !casting_date.empty? ? casting_date : prev["sourceUpdated"]),
    "fetchedAt"     => today,
    "metals"        => { "silver" => { "metal" => casting } },
    "market"        => {
      "silver"        => market,
      "source"        => "田中貴金属（銀・店頭小売価格・税込）",
      "sourceUpdated" => (market_date && !market_date.empty? ? market_date : prev.dig("market", "sourceUpdated")),
    },
  }
  File.write(PRICES, JSON.pretty_generate(prices) + "\n")

  history = load_json(HISTORY, [])
  history = [] unless history.is_a?(Array)
  upsert_history(history, today, casting, market)
  File.write(HISTORY, JSON.pretty_generate(history) + "\n")

  puts "OK: casting=#{casting} market=#{market} date=#{today} (history #{history.size} pts)"
  0
end

exit(main) if $PROGRAM_NAME == __FILE__
