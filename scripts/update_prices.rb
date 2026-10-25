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
# どちらかの取得・解析に失敗した場合:
#   - prices.json（計算ツール用の最新値）は前回値で補完する
#   - prices-history.json には「実際に取得できた値」だけを記録する（補完値は入れない）
#   - 終了コード1で失敗を知らせる（CI側でコミット・デプロイは継続し、通知のみ失敗にする）

require "net/http"
require "uri"
require "json"
require "date"

SEAFORCE_URL = "https://www.kakounet.com/cast/cast/price.html"
TANAKA_URL   = "https://gold.tanaka.co.jp/commodity/souba/"

PRICES  = File.expand_path("../yuai2026/prices.json", __dir__)
HISTORY = File.expand_path("../yuai2026/prices-history.json", __dir__)

# 2026-10-23 から田中貴金属が bot 向け UA に HTTP 503 を返すようになったため、
# 一般的なブラウザ相当のリクエストヘッダで取得する（公開価格を1日1回参照するのみ）。
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
HEADERS = {
  "User-Agent"      => UA,
  "Accept"          => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
  "Accept-Language" => "ja,en-US;q=0.9,en;q=0.8",
}.freeze

def fetch_html(url, tries: 3)
  attempt = 0
  begin
    attempt += 1
    uri = URI.parse(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.open_timeout = 30
    http.read_timeout = 30
    res = http.get(uri.request_uri, HEADERS.dup)
    raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

    res.body.force_encoding("UTF-8")
  rescue StandardError => e
    if attempt < tries
      warn "  retry #{attempt}/#{tries - 1}（#{url}）: #{e}"
      sleep attempt * 5
      retry
    end
    raise
  end
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

  # 今回フレッシュに取得できた値（履歴にはこれだけを記録する）
  fresh_casting = casting
  fresh_market  = market
  failed = []
  failed << "Seaforce(鋳造)" if fresh_casting.nil?
  failed << "田中貴金属(一般)" if fresh_market.nil?

  # 計算ツール用の最新値（prices.json）は前回値で補完して動作を維持する
  casting ||= prev_casting
  market  ||= prev_market

  if casting.nil? && market.nil?
    warn "ERROR: 両系列とも取得できず、前回値も無いため更新しません"
    return 1
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
  # 補完値を「その日の観測値」として残さない：実測できた系列だけを記録する
  unless fresh_casting.nil? && fresh_market.nil?
    upsert_history(history, today, fresh_casting, fresh_market)
  end
  File.write(HISTORY, JSON.pretty_generate(history) + "\n")

  puts "OK: casting=#{casting}#{fresh_casting.nil? ? '(補完)' : ''} " \
       "market=#{market}#{fresh_market.nil? ? '(補完)' : ''} " \
       "date=#{today} (history #{history.size} pts)"

  unless failed.empty?
    # ファイルは前回値で更新済み。取得失敗は終了コード1で知らせる（CIで失敗通知）。
    warn "ERROR: 価格取得に失敗（前回値で補完）: #{failed.join(', ')}"
    return 1
  end
  0
end

exit(main) if $PROGRAM_NAME == __FILE__
