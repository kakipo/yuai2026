#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

# 銀地金の価格を取得して保存する（GitHub Actions から日次実行）。
#
# 系列:
#   - 鋳造相場 (casting): Seaforce(加工net) SV925/950 地金単価（税込・円/g）
#   - 一般相場 (market):  田中貴金属 銀 店頭小売価格（税込・円/g）
#       ※2026-10-23 以降、GitHub Actions のIP帯には HTTP 503 を返すため取得不能。
#         1日1回だけ試行し、復活したら自動で記録を再開する（失敗しても異常扱いしない）。
#   - 銀スポット (spot): LBMA 公式の銀価格（USD/トロイオンス）× ECB 公式レート
#       （Frankfurter API の USD/JPY）から換算した 円/g（税抜）。
#       どちらもプログラム利用前提の公開APIで、履歴ごと取得して自動バックフィルする。
#       ※当初は stooq を使ったが、GitHub Actions の共有IPでは回数制限に当たるため乗り換えた。
#
# 出力:
#   - yuai2026/prices.json         … 最新スナップショット（ページの地金単価反映に使用）
#   - yuai2026/prices-history.json … 日次の時系列（チャート用）
#
# 方針:
#   - 履歴には「実際に観測できた値」だけを記録する（補完値は入れない）
#   - prices.json（計算ツール用の最新値）は前回値で補完して動作を維持する
#   - Seaforce またはスポット（LBMA/為替）の取得に失敗したら終了コード1（CI側で通知。コミット・デプロイは継続）

require "net/http"
require "uri"
require "json"
require "date"

SEAFORCE_URL  = "https://www.kakounet.com/cast/cast/price.html"
TANAKA_URL    = "https://gold.tanaka.co.jp/commodity/souba/"
# スポット履歴の取得開始日（ツールの履歴開始に合わせる）
SPOT_FROM_DATE = "2026-06-01"
# LBMA 銀価格（全履歴JSON・USD/トロイオンス）
LBMA_AG_URL = "https://prices.lbma.org.uk/json/silver.json"
# ECB 公式レート（Frankfurter API）の USD/JPY 履歴
FX_URL = "https://api.frankfurter.dev/v1/#{SPOT_FROM_DATE}..?base=USD&symbols=JPY"

PRICES  = File.expand_path("../yuai2026/prices.json", __dir__)
HISTORY = File.expand_path("../yuai2026/prices-history.json", __dir__)

TROY_OUNCE_G = 31.1034768

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

# --- 銀スポット（LBMA × ECB/Frankfurter） ------------------------------------
# 解析失敗時の調査用に、レスポンス冒頭を潰して添える
def body_snippet(s)
  s.to_s.gsub(/\s+/, " ").strip[0, 120]
end

# LBMA 銀価格JSON: [{"d":"YYYY-MM-DD","v":[USD,GBP,EUR]}, ...] → { 日付 => USD/oz }
def parse_lbma_silver(body)
  data = JSON.parse(body)
  raise "LBMA: 配列ではありません（#{body_snippet(body)}）" unless data.is_a?(Array)

  series = {}
  data.each do |row|
    d = row["d"]
    v = row.dig("v", 0)
    next unless d.is_a?(String) && d >= SPOT_FROM_DATE
    next unless v.is_a?(Numeric) && v.positive?

    series[d] = v.to_f
  end
  raise "LBMA: #{SPOT_FROM_DATE} 以降の有効データがありません（#{body_snippet(body)}）" if series.empty?

  series
end

# Frankfurter: {"rates":{"YYYY-MM-DD":{"JPY":155.1}, ...}} → { 日付 => JPY }
def parse_usdjpy(body)
  data = JSON.parse(body)
  rates = data["rates"]
  raise "Frankfurter: rates がありません（#{body_snippet(body)}）" unless rates.is_a?(Hash)

  series = {}
  rates.each do |d, h|
    v = h.is_a?(Hash) ? h["JPY"] : nil
    series[d] = v.to_f if v.is_a?(Numeric) && v.positive?
  end
  raise "Frankfurter: JPY の有効データがありません（#{body_snippet(body)}）" if series.empty?

  series
end

# 銀USD/oz と USD/JPY から 円/g（税抜）のスポット系列を作る（共通日付のみ）
def spot_series_jpy_per_g(ag_usd, jpy)
  (ag_usd.keys & jpy.keys).to_h { |d| [d, (ag_usd[d] / TROY_OUNCE_G * jpy[d]).round(2)] }
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

# 履歴に含まれる日付のうち spot が未記録のものへバックフィルする。
# 当日分はエントリが無くても spot だけで作成する（鋳造が休みの日でも記録される）。
def backfill_spot(history, spots, today)
  history.each do |e|
    next unless e["spot"].nil?

    v = spots[e["date"]]
    e["spot"] = v if v
  end
  if spots[today] && history.none? { |e| e["date"] == today }
    history << { "date" => today, "spot" => spots[today] }
  end
  history.sort_by! { |e| e["date"] }
  history
end

def try_fetch(label)
  yield
rescue StandardError => e
  warn "WARN: #{label} の取得に失敗: #{e}"
  nil
end

def main
  prev = load_json(PRICES, {})
  prev_casting = prev.dig("metals", "silver", "metal")
  prev_market  = prev.dig("market", "silver")
  prev_spot    = prev.dig("spot", "silver")

  casting = casting_date = nil
  if (html = try_fetch("Seaforce") { fetch_html(SEAFORCE_URL) })
    casting      = try_fetch("Seaforce parse") { parse_casting_silver(html) }
    casting_date = parse_casting_date(html) rescue ""
  end

  # 田中はブロック中が常態のため1回だけ試行（復活検知用）。失敗しても異常としない。
  market = market_date = nil
  if (html = try_fetch("Tanaka（取得不能が続いても正常動作）") { fetch_html(TANAKA_URL, tries: 1) })
    market      = try_fetch("Tanaka parse") { parse_market_silver(html) }
    market_date = parse_market_date(html) rescue ""
  end

  ag    = try_fetch("LBMA 銀価格") { parse_lbma_silver(fetch_html(LBMA_AG_URL)) }
  jpy   = try_fetch("Frankfurter USD/JPY") { parse_usdjpy(fetch_html(FX_URL)) }
  spots = (ag && jpy) ? spot_series_jpy_per_g(ag, jpy) : nil

  # 今回フレッシュに取得できた値（履歴にはこれだけを記録する）
  fresh_casting = casting
  fresh_market  = market
  failed = []
  failed << "Seaforce(鋳造)" if fresh_casting.nil?
  failed << "スポット(LBMA/為替)" if spots.nil?

  # 計算ツール用の最新値（prices.json）は前回値で補完して動作を維持する
  casting ||= prev_casting
  market  ||= prev_market

  latest_spot_date, latest_spot = spots&.max_by { |d, _| d }

  if casting.nil? && spots.nil? && market.nil?
    warn "ERROR: 全系列とも取得できず、前回値も無いため更新しません"
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
    "spot"          => {
      "silver"        => (latest_spot || prev_spot),
      "source"        => "銀スポット（LBMA銀価格 × ECB USD/JPY 換算・税抜・円/g）",
      "sourceUpdated" => (latest_spot_date || prev.dig("spot", "sourceUpdated")),
    },
  }
  File.write(PRICES, JSON.pretty_generate(prices) + "\n")

  history = load_json(HISTORY, [])
  history = [] unless history.is_a?(Array)
  unless fresh_casting.nil? && fresh_market.nil?
    upsert_history(history, today, fresh_casting, fresh_market)
  end
  backfill_spot(history, spots, today) if spots
  File.write(HISTORY, JSON.pretty_generate(history) + "\n")

  spot_note = latest_spot ? "#{latest_spot} (#{latest_spot_date})" : "取得失敗"
  puts "OK: casting=#{casting}#{fresh_casting.nil? ? '(補完)' : ''} " \
       "market=#{fresh_market || '欠測'} spot=#{spot_note} " \
       "date=#{today} (history #{history.size} pts)"

  unless failed.empty?
    warn "ERROR: 価格取得に失敗: #{failed.join(', ')}"
    return 1
  end
  0
end

exit(main) if $PROGRAM_NAME == __FILE__
