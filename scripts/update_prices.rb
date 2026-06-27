#!/usr/bin/env ruby
# encoding: utf-8
# frozen_string_literal: true

# Seaforce(加工net) の鋳造料金ページから本日のシルバー地金単価(税込)を取得し、
# yuai2026/prices.json を更新する。GitHub Actions から日次で実行する想定。
#
# 取得・解析に失敗した場合は既存の prices.json を維持し、終了コード0で抜ける
# （=デプロイは継続し、サイトは前回値で動作する）。

require "net/http"
require "uri"
require "json"
require "date"

URL = "https://www.kakounet.com/cast/cast/price.html"
OUT = File.expand_path("../yuai2026/prices.json", __dir__)
UA  = "Mozilla/5.0 (compatible; tools.kakipo.com price-bot; +https://tools.kakipo.com/yuai2026/)"

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

# 例: <span class=" d-largest_font">SV925/950&nbsp; &nbsp; ￥476</span>
def parse_silver_price(html)
  m = html.match(%r{SV925/950[^￥]*￥\s*([\d,]+)})
  raise "SV925/950 の地金価格が見つかりません" unless m

  m[1].delete(",").to_i
end

# 例: 本日の地金価格(税込)　　2026/6/26(金)更新
def parse_source_date(html)
  m = html.match(%r{本日の地金価格[^0-9]*(\d{4}/\d{1,2}/\d{1,2})})
  m ? m[1] : ""
end

def main
  begin
    html    = fetch_html(URL)
    silver  = parse_silver_price(html)
    updated = parse_source_date(html)
  rescue StandardError => e
    warn "WARN: 価格取得に失敗したため既存値を維持します: #{e}"
    return 0
  end

  data = {
    "source"        => URL,
    "note"          => "地金単価は税込・目安。実際の請求は仕上がり時の相場によります。",
    "sourceUpdated" => updated,
    "fetchedAt"     => Date.today.to_s,
    "metals"        => { "silver" => { "metal" => silver } },
  }

  File.write(OUT, JSON.pretty_generate(data) + "\n")
  puts "OK: silver=#{silver} (税込) sourceUpdated=#{updated}"
  0
end

exit(main) if $PROGRAM_NAME == __FILE__
