#!/usr/bin/env ruby
# frozen_string_literal: true

# Lowe's Order History — single-file Sinatra app to browse, search, and view
# orders/quotes/materials synced by `lowes-cli` into ~/.local/share/lowes/.

require 'bundler/inline'

gemfile do
  source 'https://rubygems.org'
  gem 'sinatra'
  gem 'puma'
  gem 'rackup'
end

require 'sinatra'
require 'json'
require 'erb'
require 'date'
require 'net/http'

DATA_ROOT   = ENV['LOWES_DATA_ROOT'] || File.expand_path('~/.local/share/lowes')
INDEX_PATH  = File.join(DATA_ROOT, 'index.json')
MATERIALS   = File.join(DATA_ROOT, 'materials.json')
PRICES_DIR  = File.join(DATA_ROOT, 'prices')
WEB_RB_PATH = File.expand_path(__FILE__)

def load_templates
  return @templates if @templates

  raw = File.read(WEB_RB_PATH).force_encoding('UTF-8').split(/^__END__$/, 2).last.to_s
  parts = raw.split(/^@@(\w+)\s*\n/)
  parts.shift
  @templates = parts.each_slice(2).to_h
end

def template(name)
  load_templates.fetch(name.to_s) { raise "Unknown template: #{name}" }
end

helpers do
  def h(text)
    Rack::Utils.escape_html(text.to_s)
  end

  def render_page(name, locals = {})
    locals.each { |k, v| instance_variable_set("@#{k}", v) }
    @_title = locals[:title] || "Lowe's Orders"
    @_content = ERB.new(template(name)).result(binding)
    ERB.new(template('layout')).result(binding)
  end

  def money(amount)
    return '—' if amount.nil? || amount.to_s.empty?

    n = amount.is_a?(Numeric) ? amount : amount.to_s.gsub(/[^0-9.\-]/, '').to_f
    sign = n.negative? ? '-' : ''
    "#{sign}$#{format('%.2f', n.abs)}"
  end

  def parse_date(str)
    Date.parse(str.to_s)
  rescue StandardError
    nil
  end

  def relative_date(str)
    d = parse_date(str)
    return h(str.to_s) unless d

    days = (Date.today - d).to_i
    label =
      case days
      when 0 then 'today'
      when 1 then 'yesterday'
      when 2..30 then "#{days}d ago"
      when 31..365 then "#{(days / 30.0).round}mo ago"
      else "#{(days / 365.0).round}y ago"
      end
    %(<span title="#{h(d.strftime('%A, %B %-d, %Y'))}">#{h(d.strftime('%b %-d, %Y'))} <span class="text-zinc-500 dark:text-zinc-400">· #{label}</span></span>)
  end

  def index_data
    mtime = File.exist?(INDEX_PATH) ? File.mtime(INDEX_PATH).to_f : 0.0
    cache = self.class.instance_variable_get(:@index_cache)
    return cache[:data] if cache && cache[:mtime] == mtime && cache[:all_orders]

    data = File.exist?(INDEX_PATH) ? JSON.parse(File.read(INDEX_PATH)) : { 'orders' => {}, 'quotes' => {} }
    all_orders = (data['orders'] || {}).map { |id, m|
      m.merge('order_id' => id, '_date' => parse_date(m['date']))
    }.sort_by { |o| [o['_date'] ? -o['_date'].to_time.to_i : 0, o['order_id']] }

    self.class.instance_variable_set(:@index_cache,
      { mtime: mtime, data: data, all_orders: all_orders })
    @all_orders = all_orders
    data
  rescue StandardError
    { 'orders' => {}, 'quotes' => {} }
  end

  def all_orders
    index_data
    @all_orders ||= self.class.instance_variable_get(:@index_cache)&.dig(:all_orders) || []
  end

  def years
    all_orders.map { |o| o['year'] }.compact.uniq.sort.reverse
  end

  def load_order(id)
    meta = index_data.dig('orders', id) or return nil
    path = File.join(DATA_ROOT, meta['file'])
    return nil unless File.exist?(path)

    cache = self.class.instance_variable_get(:@order_cache) || {}
    mtime = File.mtime(path).to_f
    cached = cache[id]
    return cached[:data] if cached && cached[:mtime] == mtime

    data = JSON.parse(File.read(path))
    cache[id] = { mtime: mtime, data: data }
    self.class.instance_variable_set(:@order_cache, cache)
    data
  rescue StandardError
    nil
  end

  def load_quote(id)
    meta = index_data.dig('quotes', id) or return nil
    path = File.join(DATA_ROOT, meta['file'])
    return nil unless File.exist?(path)
    JSON.parse(File.read(path))
  rescue StandardError
    nil
  end

  def filter_orders(orders, year: nil, query: nil)
    out = orders
    out = out.select { |o| o['year'].to_i == year.to_i } if year
    if query && !query.empty?
      q = query.downcase
      out = out.select do |o|
        next true if o['order_id'].to_s.downcase.include?(q)

        full = load_order(o['order_id'])
        next false unless full

        items = full['items'] || []
        items.any? do |i|
          i['title'].to_s.downcase.include?(q) ||
            i['model'].to_s.downcase.include?(q) ||
            i['item_id'].to_s.downcase.include?(q)
        end
      end
    end
    out
  end

  def stats(orders)
    totals = orders.map { |o| o['total'] }.compact
    {
      count: orders.size,
      total: totals.sum,
      avg: totals.empty? ? 0 : totals.sum / totals.size,
      max: totals.max || 0,
      missing_total: orders.count { |o| o['total'].nil? }
    }
  end

  def yearly_breakdown
    years.map do |y|
      ys = all_orders.select { |o| o['year'] == y }
      [y, stats(ys)]
    end
  end

  # Compute line total + per-unit display for an item. Newer syncs
  # store explicit `line_total` / `line_was` fields (canonical, set by
  # the worker). Older syncs only have per-unit `price` and a
  # sometimes-confused `was_price`, so we fall back to a heuristic
  # that picks the interpretation giving a sensible discount.
  def item_pricing(item)
    qty = (item['qty'] || item['quantity']).to_i
    qty = 1 if qty < 1
    price = item['price'].to_f
    was = item['was_price']&.to_f

    line_total = item['line_total']&.to_f || (price * qty)
    line_was   = item['line_was']&.to_f
    if line_was.nil? && was && was.positive?
      # Heuristic for legacy JSON: was could be per-unit OR line-total
      # (Lowe's by-the-foot extractor mixed them). Pick whichever gives
      # a sensible discount — at most ~90% off.
      [was, was * qty].each do |candidate|
        if candidate > line_total && (line_total / candidate) > 0.10
          line_was = candidate
          break
        end
      end
      line_was ||= was * qty
    end

    {
      qty: qty,
      per_unit: price,
      line_total: line_total,
      line_was: line_was,
      show_per_unit: qty > 1
    }
  end

  # Pick the item to display in a search result row. When a query is
  # active, surface the first item whose title/model/item_id matches —
  # otherwise users see the *first* item of every order even when the
  # match is on item 5.
  def display_item(items, query)
    return items.first if query.to_s.empty? || items.empty?

    q = query.downcase
    items.find { |i|
      i['title'].to_s.downcase.include?(q) ||
        i['model'].to_s.downcase.include?(q) ||
        i['item_id'].to_s.downcase.include?(q)
    } || items.first
  end

  def highlight(text, query)
    return h(text) if query.to_s.empty?

    escaped = h(text)
    pattern = Regexp.new(Regexp.escape(h(query)), Regexp::IGNORECASE)
    escaped.gsub(pattern) { |m| %(<mark class="bg-amber-200 dark:bg-amber-400/30 text-amber-900 dark:text-amber-100 rounded px-0.5">#{m}</mark>) }
  end

  def materials
    File.exist?(MATERIALS) ? JSON.parse(File.read(MATERIALS)) : []
  end

  def price_key(material)
    material['model'] || material['item_id'] || material['url']
  end

  def slug(key)
    key.to_s.gsub(/[^A-Za-z0-9._-]/, '_')[0, 80]
  end

  def price_history(key)
    file = File.join(PRICES_DIR, "#{slug(key)}.ndjson")
    return [] unless File.exist?(file)
    File.readlines(file).map { |l| JSON.parse(l) }
  rescue StandardError
    []
  end

  def latest_price(key)
    price_history(key).last
  end

  def sparkline(values, width: 120, height: 32)
    pts = values.compact.map(&:to_f)
    return '' if pts.size < 2
    min, max = pts.min, pts.max
    range = (max - min).zero? ? 1.0 : (max - min)
    coords = pts.each_with_index.map do |v, i|
      x = (i.to_f / (pts.size - 1) * width).round(2)
      y = (height - ((v - min) / range * (height - 4)) - 2).round(2)
      "#{x},#{y}"
    end
    %(<svg width="#{width}" height="#{height}" viewBox="0 0 #{width} #{height}" class="text-blue-600 dark:text-blue-400 inline-block align-middle"><polyline fill="none" stroke="currentColor" stroke-width="1.5" points="#{coords.join(' ')}"/></svg>)
  end

  def proxy_image(url)
    return '' unless url
    full = url.start_with?('//') ? "https:#{url}" : url.start_with?('/') ? "https://www.lowes.com#{url}" : url
    "/img?u=#{Rack::Utils.escape(full)}"
  end
end

set :environment, ENV['RACK_ENV'] || :production
set :bind, ENV['BIND'] || '127.0.0.1'
set :port, ENV['PORT'] || 4567
set :protection, host_authorization: { permitted_hosts: [] }

PAGE_SIZE = 100
DENSITIES = %w[compact comfortable gallery].freeze

# ---------- Routes ----------

get '/' do
  year = params[:year] && !params[:year].empty? ? params[:year].to_i : nil
  query = params[:q].to_s.strip
  density = DENSITIES.include?(params[:density]) ? params[:density] : 'comfortable'
  page = [params[:page].to_i, 1].max
  orders = filter_orders(all_orders, year: year, query: query)
  total_pages = [((orders.size - 1) / PAGE_SIZE) + 1, 1].max
  page = [page, total_pages].min
  paged = orders.slice((page - 1) * PAGE_SIZE, PAGE_SIZE) || []
  render_page :index,
              orders: paged,
              page: page,
              total_pages: total_pages,
              total_count: orders.size,
              year: year,
              query: query,
              density: density,
              years: years,
              stats: stats(orders),
              title: query.empty? ? "Lowe's Orders" : "Search: #{query}"
end

get '/orders/:id' do
  order_id = params[:id]
  halt 400, 'bad id' unless order_id =~ /\A[\w-]+\z/

  order = load_order(order_id) or halt 404, 'order not found'
  meta = index_data.dig('orders', order_id) || {}
  render_page :order, order: order, meta: meta, order_id: order_id,
                      title: "Order #{order_id}"
end

get '/quotes' do
  rows = (index_data['quotes'] || {}).map { |id, m| m.merge('quote_id' => id) }
                                     .sort_by { |q| q['date'].to_s }.reverse
  render_page :quotes, quotes: rows, title: 'Quotes'
end

get '/quotes/:id' do
  q = load_quote(params[:id]) or halt 404, 'quote not found'
  render_page :quote, quote: q, title: "Quote #{params[:id]}"
end

get '/materials' do
  rows = materials.map do |m|
    history = price_history(price_key(m))
    m.merge('latest' => history.last,
            'history' => history,
            'sparkline' => sparkline(history.map { |hh| hh['price'] }))
  end
  render_page :materials, materials: rows, title: 'Materials'
end

get '/prices/:key' do
  history = price_history(params[:key])
  halt 404, 'no history' if history.empty?
  render_page :prices, key: params[:key], history: history,
                       title: "Prices: #{params[:key]}"
end

get '/stats' do
  render_page :stats, yearly: yearly_breakdown, overall: stats(all_orders),
                      title: 'Stats'
end

# Square SVG returned when an upstream image is gone — Lowe's delists
# products and either 404s or returns an HTML error page, which the
# browser would otherwise render as the broken-image icon.
PLACEHOLDER_SVG = <<~SVG
  <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100" preserveAspectRatio="xMidYMid meet">
    <rect width="100" height="100" fill="#f4f4f5"/>
    <g fill="none" stroke="#a1a1aa" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <rect x="22" y="28" width="56" height="44" rx="4"/>
      <circle cx="36" cy="44" r="4"/>
      <path d="M22 60l14-12 16 14 10-8 16 14"/>
    </g>
    <text x="50" y="86" text-anchor="middle" font-family="system-ui, sans-serif" font-size="9" fill="#71717a">delisted</text>
  </svg>
SVG

ALLOWED_IMG_HOSTS = %w[lowes.com lowescdn.com].freeze

get '/img' do
  url = params[:u].to_s
  halt 400 unless url.start_with?('https://')
  uri = URI.parse(url)
  host = uri.host.to_s
  halt 400 unless ALLOWED_IMG_HOSTS.any? { |d| host == d || host.end_with?(".#{d}") }
  # Lowe's serves a "no image available" GIF for delisted/unknown
  # products. Treat that path as missing so the user sees our cleaner
  # placeholder rather than Lowe's stock graphic.
  if url.include?('no_image_available')
    content_type 'image/svg+xml'
    cache_control :public, max_age: 86_400
    return PLACEHOLDER_SVG
  end
  res = Net::HTTP.get_response(uri)
  if res.is_a?(Net::HTTPSuccess) && res['content-type'].to_s.start_with?('image/')
    content_type res['content-type']
    cache_control :public, max_age: 86_400
    res.body
  else
    content_type 'image/svg+xml'
    cache_control :public, max_age: 86_400
    PLACEHOLDER_SVG
  end
end

get '/health' do
  content_type :json
  klass = Sinatra::Application
  index_size = klass.instance_variable_get(:@index_cache)&.dig(:all_orders)&.size
  index_mtime = klass.instance_variable_get(:@index_cache)&.dig(:mtime)
  JSON.pretty_generate(
    orders_indexed: index_size || all_orders.size,
    index_mtime: index_mtime ? Time.at(index_mtime).utc.iso8601 : nil,
    cache: { orders_loaded: (klass.instance_variable_get(:@order_cache) || {}).size },
    process: { pid: Process.pid, uptime_s: (Time.now - $started_at).to_i }
  )
end

$started_at = Time.now
Sinatra::Application.run! if $PROGRAM_NAME == __FILE__

__END__

@@layout
<!DOCTYPE html>
<html lang="en" class="h-full">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title><%= h(@_title) %></title>
  <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24' fill='%23004990'%3E%3Cpath d='M12 2L2 9v13h6v-7h8v7h6V9z'/%3E%3C/svg%3E" type="image/svg+xml">
  <script src="https://cdn.tailwindcss.com"></script>
  <style>
    :where(a, button, input, [tabindex]):focus-visible {
      outline: 2px solid #2563eb; outline-offset: 2px; border-radius: 0.375rem;
    }
    @media (prefers-reduced-motion: reduce) {
      *, *::before, *::after { animation-duration: 0.01ms !important; transition-duration: 0.01ms !important; }
      .group-hover\:scale-105 { transform: none !important; }
    }
  </style>
</head>
<body class="h-full bg-white dark:bg-zinc-950 text-zinc-900 dark:text-zinc-100 antialiased">
  <header class="sticky top-0 z-10 border-b border-zinc-200 dark:border-zinc-800 bg-white/80 dark:bg-zinc-950/80 backdrop-blur">
    <div class="max-w-6xl mx-auto px-4 py-3 flex items-center gap-4">
      <a href="/" aria-label="Home" class="flex items-center gap-2 font-semibold text-blue-700 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-300 shrink-0">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="currentColor" class="w-5 h-5" aria-hidden="true"><path d="M12 2L2 9v13h6v-7h8v7h6V9z"/></svg>
        <span class="hidden sm:inline">Lowe's Orders</span>
      </a>
      <form action="/" method="get" class="flex-1 max-w-xl ml-auto flex gap-2">
        <div class="relative flex-1">
          <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="w-4 h-4 absolute left-3 top-2.5 text-zinc-500 dark:text-zinc-400"><path fill-rule="evenodd" d="M9 3.5a5.5 5.5 0 100 11 5.5 5.5 0 000-11zM2 9a7 7 0 1112.452 4.391l3.328 3.329a.75.75 0 11-1.06 1.06l-3.329-3.328A7 7 0 012 9z" clip-rule="evenodd"/></svg>
          <input type="search" name="q" value="<%= h(@query) %>" placeholder="Search items, models, order IDs…" aria-label="Search orders" autocomplete="off"
                 class="w-full bg-zinc-100 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-lg pl-9 pr-3 py-2 text-sm text-zinc-900 dark:text-zinc-100 placeholder-zinc-600 dark:placeholder-zinc-400 focus:outline-none focus:ring-2 focus:ring-blue-500 focus:border-blue-500">
        </div>
        <% if @year %><input type="hidden" name="year" value="<%= h(@year) %>"><% end %>
        <% if @density && @density != 'comfortable' %><input type="hidden" name="density" value="<%= h(@density) %>"><% end %>
      </form>
      <nav class="flex items-center gap-3 text-sm shrink-0">
        <a href="/quotes" class="text-zinc-700 dark:text-zinc-300 hover:text-blue-700 dark:hover:text-blue-400">Quotes</a>
        <a href="/materials" class="text-zinc-700 dark:text-zinc-300 hover:text-blue-700 dark:hover:text-blue-400">Materials</a>
        <a href="/stats" class="text-zinc-700 dark:text-zinc-300 hover:text-blue-700 dark:hover:text-blue-400">Stats</a>
      </nav>
    </div>
  </header>
  <main class="max-w-6xl mx-auto px-4 py-6">
    <%= @_content %>
  </main>
  <footer class="max-w-6xl mx-auto px-4 py-8 text-xs text-zinc-500 dark:text-zinc-400">
    <code><%= h(DATA_ROOT.sub(Dir.home, '~')) %></code>
  </footer>
</body>
</html>

@@index
<div class="mb-6 flex items-end justify-between gap-4 flex-wrap">
  <div>
    <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">
      <% if @query.empty? && !@year %>
        All orders
      <% elsif @query.empty? %>
        <%= h(@year) %>
      <% else %>
        Search: <span class="text-blue-700 dark:text-blue-300">"<%= h(@query) %>"</span><% if @year %> in <%= h(@year) %><% end %>
      <% end %>
    </h1>
    <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1">
      <%= @stats[:count] %> order<%= 's' if @stats[:count] != 1 %>
      · <span class="text-zinc-800 dark:text-zinc-200 tabular-nums"><%= money(@stats[:total]) %></span> total
      <% if @stats[:count].positive? %>· avg <span class="tabular-nums"><%= money(@stats[:avg]) %></span><% end %>
      <% if @total_pages > 1 %>· <span class="text-zinc-500 dark:text-zinc-400">page <%= @page %>/<%= @total_pages %></span><% end %>
    </p>
  </div>

  <div class="flex items-center gap-1 flex-wrap">
    <%
      qs = ->(year: @year, density: @density) {
        parts = []
        parts << "year=#{year}" if year
        parts << "q=#{Rack::Utils.escape(@query)}" unless @query.empty?
        parts << "density=#{density}" unless density == 'comfortable'
        parts.empty? ? '/' : "/?#{parts.join('&')}"
      }
    %>
    <a href="<%= qs.call(year: nil) %>"<%= ' aria-current="page"' if @year.nil? %> class="px-3 py-1.5 rounded-md text-xs font-medium <%= @year.nil? ? 'bg-blue-100 dark:bg-blue-500/20 text-blue-800 dark:text-blue-300 ring-1 ring-blue-400 dark:ring-blue-500/30' : 'text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100' %>">All years</a>
    <% @years.each do |y| %>
      <a href="<%= qs.call(year: y) %>"<%= ' aria-current="page"' if @year == y %> class="px-3 py-1.5 rounded-md text-xs font-medium tabular-nums <%= @year == y ? 'bg-blue-100 dark:bg-blue-500/20 text-blue-800 dark:text-blue-300 ring-1 ring-blue-400 dark:ring-blue-500/30' : 'text-zinc-700 dark:text-zinc-300 hover:text-zinc-900 dark:hover:text-zinc-100' %>"><%= y %></a>
    <% end %>
  </div>
</div>

<div class="mb-4 flex items-center justify-end gap-3">
  <div class="inline-flex items-center rounded-md border border-zinc-200 dark:border-zinc-800 overflow-hidden text-xs" role="group" aria-label="Display density">
    <% [
      ['compact',     'M2 5h16M2 10h16M2 15h16'],
      ['comfortable', 'M2 4h16v4H2zM2 12h16v4H2z'],
      ['gallery',     'M3 3h6v6H3zM11 3h6v6h-6zM3 11h6v6H3zM11 11h6v6h-6z']
    ].each do |val, path| %>
      <a href="<%= qs.call(density: val) %>" title="<%= val.capitalize %>" aria-label="<%= val.capitalize %> density"<%= ' aria-current="true"' if @density == val %> class="px-2.5 py-1.5 transition <%= @density == val ? 'bg-blue-100 dark:bg-blue-500/20 text-blue-800 dark:text-blue-300' : 'text-zinc-600 dark:text-zinc-400 hover:text-zinc-900 dark:hover:text-zinc-100 hover:bg-zinc-50 dark:hover:bg-zinc-900' %>">
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" class="w-4 h-4"><path d="<%= path %>"/></svg>
      </a>
    <% end %>
  </div>
</div>

<% if @orders.empty? %>
  <div class="text-zinc-600 dark:text-zinc-400 text-sm border border-zinc-200 dark:border-zinc-800 rounded-lg p-6">
    <% if @query.empty? && @year.nil? %>
      No orders cached yet. Run <code class="text-xs bg-zinc-100 dark:bg-zinc-900 px-1.5 py-0.5 rounded">lowes sync</code> to fetch them.
    <% else %>
      No matching orders.
    <% end %>
  </div>
<% else %>
  <% if @density == 'gallery' %>
    <ul class="grid grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 gap-3">
      <% @orders.each do |o|
           full = load_order(o['order_id'])
           items = full ? (full['items'] || []) : []
           first_item = display_item(items, @query)
           extra = items.size - 1
      %>
        <li>
          <a href="/orders/<%= h(o['order_id']) %>" class="group block rounded-lg overflow-hidden border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 hover:border-zinc-300 dark:hover:border-zinc-700 transition">
            <div class="relative aspect-square bg-zinc-100 dark:bg-zinc-800">
              <% if first_item && (first_item['image_link'] || first_item['image_url']) %>
                <img src="<%= h(proxy_image(first_item['image_link'] || first_item['image_url'])) %>" alt="" loading="lazy" class="absolute inset-0 w-full h-full object-contain p-2 group-hover:scale-105 transition-transform duration-200">
              <% else %>
                <div class="absolute inset-0 flex items-center justify-center text-zinc-400 dark:text-zinc-600 text-xs">no image</div>
              <% end %>
              <% if extra.positive? %>
                <span class="absolute top-1.5 left-1.5 inline-flex items-center rounded bg-zinc-900/70 text-white px-1.5 py-0.5 text-[10px] font-medium tabular-nums backdrop-blur">+<%= extra %></span>
              <% end %>
              <div class="absolute bottom-0 left-0 right-0 px-2 py-1.5 bg-gradient-to-t from-black/80 via-black/40 to-transparent text-white flex items-end justify-between gap-2">
                <span class="text-[11px] tabular-nums opacity-90"><%= h(parse_date(o['date'])&.strftime('%b %-d, %Y') || o['date']) %></span>
                <span class="text-sm font-semibold tabular-nums"><%= money(o['total']) %></span>
              </div>
            </div>
            <div class="px-3 py-2 text-xs text-zinc-700 dark:text-zinc-300 leading-snug line-clamp-3 min-h-[4.5rem]">
              <% if first_item %>
                <%= highlight(first_item['title'].to_s, @query) %>
              <% else %>
                <span class="italic text-zinc-500 dark:text-zinc-400">No items recorded</span>
              <% end %>
            </div>
          </a>
        </li>
      <% end %>
    </ul>
  <% else %>
    <%
      img_size    = { 'compact' => 'w-9 h-9',  'comfortable' => 'w-16 h-16' }[@density]
      card_pad    = { 'compact' => 'px-3 py-2','comfortable' => 'p-4' }[@density]
      list_gap    = { 'compact' => 'space-y-1','comfortable' => 'space-y-2' }[@density]
      title_clamp = { 'compact' => 'line-clamp-1', 'comfortable' => 'line-clamp-2' }[@density]
      total_size  = { 'compact' => 'text-sm', 'comfortable' => 'text-lg' }[@density]
    %>
    <ul class="<%= list_gap %>">
      <% @orders.each do |o|
           full = load_order(o['order_id'])
           items = full ? (full['items'] || []) : []
           first_item = display_item(items, @query)
           extra = items.size - 1
      %>
        <li>
          <a href="/orders/<%= h(o['order_id']) %>" class="block rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 hover:bg-zinc-50 dark:hover:bg-zinc-900 hover:border-zinc-300 dark:hover:border-zinc-700 <%= card_pad %> transition">
            <div class="flex items-<%= @density == 'compact' ? 'center' : 'start' %> gap-<%= @density == 'compact' ? '3' : '4' %>">
              <% if first_item && (first_item['image_link'] || first_item['image_url']) %>
                <img src="<%= h(proxy_image(first_item['image_link'] || first_item['image_url'])) %>" alt="" loading="lazy" class="<%= img_size %> rounded bg-zinc-100 dark:bg-zinc-800 object-contain shrink-0 ring-1 ring-zinc-200 dark:ring-zinc-800">
              <% else %>
                <div class="<%= img_size %> rounded bg-zinc-100 dark:bg-zinc-800 ring-1 ring-zinc-300 dark:ring-zinc-700 shrink-0"></div>
              <% end %>
              <div class="min-w-0 flex-1">
                <% if @density == 'compact' %>
                  <div class="flex items-center gap-3 min-w-0">
                    <span class="text-zinc-900 dark:text-zinc-100 font-medium truncate flex-1">
                      <% if first_item %><%= highlight(first_item['title'].to_s, @query) %><% else %><span class="italic text-zinc-500 dark:text-zinc-400">No items recorded</span><% end %>
                    </span>
                    <span class="text-xs text-zinc-500 dark:text-zinc-400 tabular-nums shrink-0 hidden sm:inline"><%= h(parse_date(o['date'])&.strftime('%b %-d, %Y') || o['date']) %></span>
                  </div>
                <% else %>
                  <div class="flex items-center gap-2 text-xs text-zinc-500 dark:text-zinc-400 mb-1 flex-wrap">
                    <span class="font-mono text-zinc-600 dark:text-zinc-400"><%= h(o['order_id']) %></span>
                    <span>·</span>
                    <span><%= relative_date(o['date']) %></span>
                    <% if o['status'] %><span>·</span><span class="uppercase tracking-wide text-[10px] font-medium"><%= h(o['status']) %></span><% end %>
                  </div>
                  <% if first_item %>
                    <div class="text-zinc-900 dark:text-zinc-100 font-medium leading-snug <%= title_clamp %>"><%= highlight(first_item['title'].to_s, @query) %></div>
                    <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1">
                      <% if first_item['model'] %>Model <span class="font-mono"><%= highlight(first_item['model'].to_s, @query) %></span><% end %>
                      <% if extra.positive? %>
                        <span class="ml-1 inline-flex items-center rounded-full bg-zinc-100 dark:bg-zinc-800 px-2 py-0.5 text-zinc-700 dark:text-zinc-300">+<%= extra %> more item<%= 's' if extra != 1 %></span>
                      <% end %>
                    </div>
                  <% else %>
                    <div class="text-zinc-500 dark:text-zinc-400 italic text-sm">No items recorded</div>
                  <% end %>
                <% end %>
              </div>
              <div class="text-right shrink-0">
                <div class="<%= total_size %> font-semibold tabular-nums text-zinc-900 dark:text-zinc-100"><%= money(o['total']) %></div>
              </div>
            </div>
          </a>
        </li>
      <% end %>
    </ul>
  <% end %>

  <% if @total_pages > 1 %>
    <%
      page_url = ->(p) {
        parts = []
        parts << "year=#{@year}" if @year
        parts << "q=#{Rack::Utils.escape(@query)}" unless @query.empty?
        parts << "density=#{@density}" if @density && @density != 'comfortable'
        parts << "page=#{p}" if p > 1
        parts.empty? ? '/' : "/?#{parts.join('&')}"
      }
    %>
    <nav class="mt-6 flex items-center justify-between gap-3 text-sm">
      <% if @page > 1 %>
        <a href="<%= page_url.call(@page - 1) %>" class="px-3 py-1.5 rounded-md border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-900">← Previous</a>
      <% else %><span></span><% end %>
      <span class="text-zinc-500 dark:text-zinc-400 tabular-nums">Page <%= @page %> of <%= @total_pages %> · <%= @total_count %> orders</span>
      <% if @page < @total_pages %>
        <a href="<%= page_url.call(@page + 1) %>" class="px-3 py-1.5 rounded-md border border-zinc-200 dark:border-zinc-800 text-zinc-700 dark:text-zinc-300 hover:bg-zinc-50 dark:hover:bg-zinc-900">Next →</a>
      <% else %><span></span><% end %>
    </nav>
  <% end %>
<% end %>

@@order
<% items = @order['items'] || [] %>
<% hero_item = items.find { |i| i['image_link'] || i['image_url'] } %>
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4 flex items-center gap-2">
  <a href="/" class="hover:text-zinc-700 dark:text-zinc-300">← All orders</a>
  <% if @meta['year'] %>
    <span class="text-zinc-300 dark:text-zinc-700">·</span>
    <a href="/?year=<%= @meta['year'] %>" class="hover:text-zinc-700 dark:text-zinc-300"><%= @meta['year'] %></a>
  <% end %>
</nav>

<% if hero_item %>
  <div class="mb-6 rounded-lg bg-zinc-100 dark:bg-zinc-900 ring-1 ring-zinc-200 dark:ring-zinc-800 overflow-hidden flex items-center justify-center">
    <% src = proxy_image(hero_item['image_link'] || hero_item['image_url']) %>
    <% if hero_item['link'] %>
      <a href="<%= h(hero_item['link']) %>" target="_blank" rel="noopener" class="block">
        <img src="<%= h(src) %>" alt="<%= h(hero_item['title']) %>" class="max-h-80 sm:max-h-96 w-auto object-contain p-6">
      </a>
    <% else %>
      <img src="<%= h(src) %>" alt="<%= h(hero_item['title']) %>" class="max-h-80 sm:max-h-96 w-auto object-contain p-6">
    <% end %>
  </div>
<% end %>

<div class="mb-6 flex items-start justify-between gap-4 flex-wrap">
  <div class="min-w-0">
    <div class="text-xs text-zinc-500 dark:text-zinc-400 font-mono"><%= h(@order_id) %></div>
    <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100 mt-1">Order placed <%= relative_date(@order['order_placed'] || @meta['date']) %></h1>
    <% if @order['status'] %>
      <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1"><%= h(@order['status']) %></p>
    <% end %>
  </div>
  <a href="https://www.lowes.com/account/orders/details/<%= h(@order_id) %>" target="_blank" rel="noopener" class="text-xs text-blue-700 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-300 shrink-0">View on lowes.com →</a>
</div>

<div class="grid md:grid-cols-3 gap-4 mb-6">
  <div class="md:col-span-2 rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5">
    <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">Items (<%= items.size %>)</h2>
    <% if items.empty? %>
      <div class="text-zinc-500 dark:text-zinc-400 text-sm italic">No items recorded for this order.</div>
    <% else %>
      <ul class="divide-y divide-zinc-200 dark:divide-zinc-800">
        <% items.each do |item| %>
          <li class="py-3 first:pt-0 last:pb-0 flex gap-4">
            <% if item['image_link'] || item['image_url'] %>
              <img src="<%= h(proxy_image(item['image_link'] || item['image_url'])) %>" alt="" loading="lazy" class="w-20 h-20 rounded bg-zinc-100 dark:bg-zinc-800 object-contain shrink-0 ring-1 ring-zinc-200 dark:ring-zinc-800">
            <% else %>
              <div class="w-20 h-20 rounded bg-zinc-100 dark:bg-zinc-800 ring-1 ring-zinc-300 dark:ring-zinc-700 shrink-0"></div>
            <% end %>
            <div class="min-w-0 flex-1">
              <% if item['link'] %>
                <a href="<%= h(item['link']) %>" target="_blank" rel="noopener" class="text-zinc-900 dark:text-zinc-100 hover:text-blue-700 dark:hover:text-blue-300 font-medium leading-snug"><%= h(item['title']) %></a>
              <% else %>
                <div class="text-zinc-900 dark:text-zinc-100 font-medium leading-snug"><%= h(item['title']) %></div>
              <% end %>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1 flex flex-wrap items-center gap-x-3 gap-y-1">
                <% if item['model']   %><span>Model <span class="font-mono text-zinc-700 dark:text-zinc-300"><%= h(item['model']) %></span></span><% end %>
                <% if item['item_id'] %><span>Item #<span class="font-mono text-zinc-700 dark:text-zinc-300"><%= h(item['item_id']) %></span></span><% end %>
                <% if item['qty'] || item['quantity'] %><span>qty <%= h(item['qty'] || item['quantity']) %></span><% end %>
              </div>
            </div>
            <div class="text-right shrink-0">
              <% pricing = item_pricing(item) %>
              <div class="font-medium tabular-nums text-zinc-900 dark:text-zinc-100"><%= money(pricing[:line_total]) %></div>
              <% if pricing[:line_was] %><div class="text-xs text-zinc-500 dark:text-zinc-400 line-through tabular-nums"><%= money(pricing[:line_was]) %></div><% end %>
              <% if pricing[:show_per_unit] %>
                <div class="text-xs text-zinc-500 dark:text-zinc-400 tabular-nums mt-0.5"><%= money(pricing[:per_unit]) %>/ea × <%= pricing[:qty] %></div>
              <% end %>
            </div>
          </li>
        <% end %>
      </ul>
    <% end %>
  </div>

  <aside class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5 self-start">
    <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">Summary</h2>
    <dl class="text-sm space-y-1.5">
      <% [['Subtotal', @order['subtotal']], ['Tax', @order['estimated_tax']]].each do |label, val| %>
        <% next if val.nil? %>
        <div class="flex justify-between gap-4"><dt class="text-zinc-600 dark:text-zinc-400"><%= label %></dt><dd class="tabular-nums text-zinc-800 dark:text-zinc-200"><%= money(val) %></dd></div>
      <% end %>
      <div class="border-t border-zinc-200 dark:border-zinc-800 pt-2 mt-2 flex justify-between gap-4">
        <dt class="text-zinc-700 dark:text-zinc-300 font-semibold">Grand total</dt>
        <dd class="tabular-nums text-zinc-900 dark:text-zinc-100 font-semibold"><%= money(@order['grand_total'] || @order['total_paid'] || @meta['total']) %></dd>
      </div>
    </dl>
    <% if @order['payment_method_last_4'] %>
      <div class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800 text-xs text-zinc-500 dark:text-zinc-400">
        Paid via card ending <span class="font-mono text-zinc-700 dark:text-zinc-300"><%= h(@order['payment_method_last_4']) %></span>
      </div>
    <% end %>
    <% if @order['ship_to'] %>
      <div class="mt-4 pt-4 border-t border-zinc-200 dark:border-zinc-800 text-xs text-zinc-500 dark:text-zinc-400">
        Ship to <span class="text-zinc-700 dark:text-zinc-300"><%= h(@order['ship_to']) %></span>
      </div>
    <% end %>
  </aside>
</div>

<details class="mt-4">
  <summary class="text-xs text-zinc-500 dark:text-zinc-400 cursor-pointer hover:text-zinc-700 dark:text-zinc-300">raw JSON</summary>
  <pre class="mt-2 bg-zinc-100 dark:bg-zinc-900 border border-zinc-200 dark:border-zinc-800 rounded-lg p-4 overflow-x-auto text-xs text-zinc-700 dark:text-zinc-300"><%= h(JSON.pretty_generate(@order)) %></pre>
</details>

@@stats
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"><a href="/" class="hover:text-zinc-700 dark:text-zinc-300">← All orders</a></nav>
<div class="mb-6">
  <h1 class="text-2xl font-semibold text-zinc-900 dark:text-zinc-100">Stats</h1>
  <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1">
    <%= @overall[:count] %> total orders ·
    <span class="text-zinc-800 dark:text-zinc-200 tabular-nums"><%= money(@overall[:total]) %></span> all-time
  </p>
</div>

<div class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 overflow-x-auto">
  <table class="w-full text-sm min-w-[32rem]">
    <thead class="bg-zinc-100 dark:bg-zinc-900 text-zinc-600 dark:text-zinc-400 text-xs uppercase tracking-wide">
      <tr>
        <th class="text-left px-4 py-2">Year</th>
        <th class="text-right px-4 py-2">Orders</th>
        <th class="text-right px-4 py-2">Total</th>
        <th class="text-right px-4 py-2">Avg</th>
        <th class="text-right px-4 py-2">Largest</th>
      </tr>
    </thead>
    <tbody class="divide-y divide-zinc-200 dark:divide-zinc-800">
      <% max_total = @yearly.map { |_, s| s[:total] }.max || 1 %>
      <% @yearly.each do |year, s| %>
        <tr class="hover:bg-zinc-100 dark:hover:bg-zinc-900/60">
          <td class="px-4 py-3"><a href="/?year=<%= year %>" class="text-blue-700 dark:text-blue-400 hover:text-blue-800 dark:hover:text-blue-300 font-medium tabular-nums"><%= year %></a></td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-700 dark:text-zinc-300"><%= s[:count] %></td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-900 dark:text-zinc-100">
            <div class="flex items-center justify-end gap-2">
              <div class="w-24 h-1.5 bg-zinc-100 dark:bg-zinc-800 rounded overflow-hidden hidden sm:block">
                <div class="h-full bg-blue-500 dark:bg-blue-500/60" style="width: <%= ((s[:total].to_f / max_total) * 100).round %>%"></div>
              </div>
              <span><%= money(s[:total]) %></span>
            </div>
          </td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-700 dark:text-zinc-300"><%= money(s[:avg]) %></td>
          <td class="px-4 py-3 text-right tabular-nums text-zinc-700 dark:text-zinc-300"><%= money(s[:max]) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>

@@quotes
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"><a href="/" class="hover:text-zinc-700 dark:text-zinc-300">← All orders</a></nav>
<h1 class="text-2xl font-semibold mb-4">Quotes</h1>
<% if @quotes.empty? %>
  <div class="text-zinc-600 dark:text-zinc-400 text-sm border border-zinc-200 dark:border-zinc-800 rounded-lg p-6">
    No quotes cached yet. Run <code class="text-xs bg-zinc-100 dark:bg-zinc-900 px-1.5 py-0.5 rounded">lowes quotes sync</code>.
  </div>
<% else %>
  <ul class="space-y-2">
    <% @quotes.each do |q| %>
      <li>
        <a href="/quotes/<%= h(q['quote_id']) %>" class="block rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 hover:bg-zinc-50 dark:hover:bg-zinc-900 hover:border-zinc-300 dark:hover:border-zinc-700 p-4 transition">
          <div class="flex items-center justify-between gap-4">
            <div class="min-w-0 flex-1">
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mb-1 flex items-center gap-2">
                <span class="font-mono"><%= h(q['quote_id']) %></span>
                <span>·</span>
                <span><%= relative_date(q['date']) %></span>
              </div>
              <div class="text-zinc-900 dark:text-zinc-100 font-medium"><%= h(q['name'] || '(unnamed)') %></div>
              <% if q['status'] %><div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1"><%= h(q['status']) %></div><% end %>
            </div>
            <div class="text-lg font-semibold tabular-nums shrink-0"><%= money(q['total']) %></div>
          </div>
        </a>
      </li>
    <% end %>
  </ul>
<% end %>

@@quote
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"><a href="/quotes" class="hover:text-zinc-700 dark:text-zinc-300">← Quotes</a></nav>
<div class="mb-6">
  <div class="text-xs text-zinc-500 dark:text-zinc-400 font-mono"><%= h(@quote['quote_id']) %></div>
  <h1 class="text-2xl font-semibold mt-1"><%= h(@quote['name'] || 'Quote') %></h1>
  <p class="text-sm text-zinc-600 dark:text-zinc-400 mt-1">
    <%= relative_date(@quote['created'] || @quote['date']) %> ·
    <span class="font-semibold tabular-nums text-zinc-900 dark:text-zinc-100"><%= money(@quote['total']) %></span>
    <% if @quote['status'] %>· <%= h(@quote['status']) %><% end %>
  </p>
  <% if @quote['link'] %><a href="<%= h(@quote['link']) %>" target="_blank" rel="noopener" class="text-xs text-blue-700 dark:text-blue-400">View on lowes.com →</a><% end %>
</div>
<div class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5">
  <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">Items (<%= (@quote['items'] || []).size %>)</h2>
  <ul class="divide-y divide-zinc-200 dark:divide-zinc-800">
    <% (@quote['items'] || []).each do |it| %>
      <li class="py-3 first:pt-0 last:pb-0 flex justify-between gap-4">
        <div class="min-w-0">
          <div class="text-zinc-900 dark:text-zinc-100 font-medium"><%= h(it['title']) %></div>
          <% if it['model'] %><div class="text-xs text-zinc-500 dark:text-zinc-400 font-mono">Model <%= h(it['model']) %></div><% end %>
        </div>
        <div class="font-medium tabular-nums shrink-0"><%= money(it['price']) %></div>
      </li>
    <% end %>
  </ul>
</div>

@@materials
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"><a href="/" class="hover:text-zinc-700 dark:text-zinc-300">← All orders</a></nav>
<h1 class="text-2xl font-semibold mb-4">Materials</h1>
<% if @materials.empty? %>
  <div class="text-zinc-600 dark:text-zinc-400 text-sm border border-zinc-200 dark:border-zinc-800 rounded-lg p-6">
    <p>No tracked materials yet.</p>
    <pre class="mt-3 text-xs bg-zinc-100 dark:bg-zinc-900 p-3 rounded"><code>lowes materials add &lt;url-or-model&gt; --nickname "2x4 stud"
lowes prices                 # refresh prices for everything tracked</code></pre>
  </div>
<% else %>
  <ul class="space-y-2">
    <% @materials.each do |m| %>
      <% latest = m['latest'] %>
      <li>
        <a href="/prices/<%= h(slug(price_key(m))) %>" class="flex items-center gap-4 rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 hover:bg-zinc-50 dark:hover:bg-zinc-900 p-4 transition">
          <% if latest && latest['image_url'] %>
            <img src="<%= h(proxy_image(latest['image_url'])) %>" alt="" loading="lazy" class="w-16 h-16 rounded bg-zinc-100 dark:bg-zinc-800 object-contain shrink-0 ring-1 ring-zinc-200 dark:ring-zinc-800">
          <% else %>
            <div class="w-16 h-16 rounded bg-zinc-100 dark:bg-zinc-800 ring-1 ring-zinc-300 dark:ring-zinc-700 shrink-0"></div>
          <% end %>
          <div class="min-w-0 flex-1">
            <div class="text-zinc-900 dark:text-zinc-100 font-medium"><%= h(m['nickname'] || latest&.dig('title') || price_key(m)) %></div>
            <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1">
              <% if m['model'] %>Model <span class="font-mono"><%= h(m['model']) %></span><% end %>
              <% if m['notes'] %>· <%= h(m['notes']) %><% end %>
            </div>
          </div>
          <div class="hidden sm:block"><%= m['sparkline'] %></div>
          <div class="text-right shrink-0">
            <% if latest %>
              <div class="font-semibold tabular-nums text-zinc-900 dark:text-zinc-100"><%= money(latest['price']) %></div>
              <% if latest['was_price'] %><div class="text-xs text-zinc-500 dark:text-zinc-400 line-through tabular-nums"><%= money(latest['was_price']) %></div><% end %>
              <div class="text-xs text-zinc-500 dark:text-zinc-400 mt-1"><%= h(latest['availability']) %></div>
            <% else %>
              <span class="text-zinc-500 dark:text-zinc-400 text-sm">no price yet</span>
            <% end %>
          </div>
        </a>
      </li>
    <% end %>
  </ul>
<% end %>

@@prices
<nav class="text-xs text-zinc-500 dark:text-zinc-400 mb-4"><a href="/materials" class="hover:text-zinc-700 dark:text-zinc-300">← Materials</a></nav>
<% latest = @history.last %>
<div class="mb-6 flex items-start gap-4">
  <% if latest && latest['image_url'] %>
    <img src="<%= h(proxy_image(latest['image_url'])) %>" alt="" class="w-24 h-24 rounded bg-zinc-100 dark:bg-zinc-800 object-contain ring-1 ring-zinc-200 dark:ring-zinc-800">
  <% end %>
  <div class="min-w-0 flex-1">
    <div class="text-xs text-zinc-500 dark:text-zinc-400 font-mono"><%= h(@key) %></div>
    <h1 class="text-xl font-semibold mt-1"><%= h(latest&.dig('title') || @key) %></h1>
    <% if latest %>
      <div class="mt-2">
        <span class="text-2xl font-bold tabular-nums"><%= money(latest['price']) %></span>
        <% if latest['was_price'] %><span class="text-zinc-500 dark:text-zinc-400 line-through ml-2 tabular-nums"><%= money(latest['was_price']) %></span><% end %>
      </div>
      <p class="text-xs text-zinc-500 dark:text-zinc-400 mt-1"><%= h(latest['availability']) %> · <%= relative_date(latest['fetched_at']) %></p>
      <% if latest['url'] %><a href="<%= h(latest['url']) %>" target="_blank" rel="noopener" class="text-xs text-blue-700 dark:text-blue-400 mt-2 inline-block">View on lowes.com →</a><% end %>
    <% end %>
  </div>
</div>

<div class="rounded-lg border border-zinc-200 dark:border-zinc-800 bg-white dark:bg-zinc-900/40 p-5 mb-4">
  <h2 class="text-sm font-semibold text-zinc-700 dark:text-zinc-300 uppercase tracking-wide mb-3">History (<%= @history.size %>)</h2>
  <%= sparkline(@history.map { |r| r['price'] }, width: 800, height: 80) %>
</div>

<div class="rounded-lg border border-zinc-200 dark:border-zinc-800 overflow-hidden">
  <table class="w-full text-sm">
    <thead class="bg-zinc-100 dark:bg-zinc-900 text-zinc-600 dark:text-zinc-400 text-xs uppercase tracking-wide">
      <tr><th class="text-left px-4 py-2">Fetched</th><th class="text-right px-4 py-2">Price</th><th class="text-right px-4 py-2">Was</th><th class="text-left px-4 py-2">Status</th></tr>
    </thead>
    <tbody class="divide-y divide-zinc-200 dark:divide-zinc-800">
      <% @history.reverse.each do |row| %>
        <tr class="hover:bg-zinc-50 dark:hover:bg-zinc-900/60">
          <td class="px-4 py-2"><%= relative_date(row['fetched_at']) %></td>
          <td class="px-4 py-2 text-right tabular-nums font-medium"><%= money(row['price']) %></td>
          <td class="px-4 py-2 text-right tabular-nums text-zinc-500 dark:text-zinc-400"><%= row['was_price'] ? money(row['was_price']) : '—' %></td>
          <td class="px-4 py-2 text-zinc-500 dark:text-zinc-400"><%= h(row['availability']) %></td>
        </tr>
      <% end %>
    </tbody>
  </table>
</div>
