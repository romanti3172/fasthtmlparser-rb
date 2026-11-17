# frozen_string_literal: true

# Benchmarks of fasthtmlparser against Nokogiri (libxml2's HTML4 parser and the HTML5 parser gumbo) and Oga: parsing
# pages, and scraping records (parse + extract). Every scraper is first checked to return exactly the same records.
#
#   bundle install          (in this folder)
#   bundle exec ruby bench.rb [seconds per measurement, default 2]
#
# The library itself is loaded from ../lib (the Gemfile points there), so the benchmark always runs the working copy.

require "fasthtmlparser"
require "nokogiri"
require "oga"

TESTDATA = File.expand_path("../testdata", __dir__)

def read(name)
  File.binread(File.join(TESTDATA, name)).force_encoding(Encoding::UTF_8)
end

def now
  Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
end

# Median time per call in microseconds: batches of calls for about `seconds`, after a one-second warm-up.
def measure(seconds)
  batch = 1
  loop do
    t = now
    batch.times { yield }
    break if now - t > 20_000_000

    batch *= 2
  end
  warm_until = now + 1_000_000_000
  yield while now < warm_until
  GC.start
  samples = []
  stop = now + (seconds * 1e9).to_i
  while now < stop
    t = now
    batch.times { yield }
    samples << (now - t) / 1000.0 / batch
  end
  samples.sort[samples.size / 2]
end

def fmt(us)
  us >= 1000 ? format("%.2f ms", us / 1000) : format("%d μs", us.round)
end

def last_word(s)
  s.split(" ").last.to_s
end

# ----- scrapers: each gives [title, price, rating] for books and [text, author, tags] for quotes -----

Q = FastHtmlParser::Query

BOOK_SCRAPERS = {
  "fasthtmlparser find" => lambda do |page|
    FastHtmlParser.parse(page).find_all(Q.by(:article).has_class("product_pod")).map do |pod|
      [
        pod.find(Q.by(:h3)).find(Q.by(:a)).attr("title"),
        pod.find(Q.by(:p).has_class("price_color")).text,
        last_word(pod.find(Q.by(:p).has_class("star-rating")).attr("class"))
      ]
    end
  end,
  "fasthtmlparser CSS" => lambda do |page|
    FastHtmlParser.parse(page).css("article.product_pod").map do |pod|
      [pod.css_first("h3 a").attr("title"), pod.css_first("p.price_color").text,
       last_word(pod.css_first("p.star-rating").attr("class"))]
    end
  end,
  "fasthtmlparser XPath" => lambda do |page|
    FastHtmlParser.parse(page).xpath("//article[@class='product_pod']").map do |pod|
      [pod.xpath_value(".//h3/a/@title"), pod.xpath_value(".//p[@class='price_color']"),
       last_word(pod.xpath_value(".//p[contains(@class,'star-rating')]/@class"))]
    end
  end,
  "Nokogiri HTML4 CSS" => lambda do |page|
    Nokogiri::HTML4(page).css("article.product_pod").map do |pod|
      [pod.at_css("h3 a")["title"], pod.at_css("p.price_color").text.strip,
       last_word(pod.at_css("p.star-rating")["class"])]
    end
  end,
  "Nokogiri HTML4 XPath" => lambda do |page|
    Nokogiri::HTML4(page).xpath("//article[@class='product_pod']").map do |pod|
      [pod.xpath("string(.//h3/a/@title)"), pod.xpath("string(.//p[@class='price_color'])").strip,
       last_word(pod.xpath("string(.//p[contains(@class,'star-rating')]/@class)"))]
    end
  end,
  "Nokogiri HTML5 CSS" => lambda do |page|
    Nokogiri::HTML5(page).css("article.product_pod").map do |pod|
      [pod.at_css("h3 a")["title"], pod.at_css("p.price_color").text.strip,
       last_word(pod.at_css("p.star-rating")["class"])]
    end
  end,
  "Nokogiri HTML5 XPath" => lambda do |page|
    Nokogiri::HTML5(page).xpath("//article[@class='product_pod']").map do |pod|
      [pod.xpath("string(.//h3/a/@title)"), pod.xpath("string(.//p[@class='price_color'])").strip,
       last_word(pod.xpath("string(.//p[contains(@class,'star-rating')]/@class)"))]
    end
  end,
  "Oga CSS" => lambda do |page|
    Oga.parse_html(page).css("article.product_pod").map do |pod|
      [pod.at_css("h3 a").get("title"), pod.at_css("p.price_color").text.strip,
       last_word(pod.at_css("p.star-rating").get("class"))]
    end
  end,
  "Oga XPath" => lambda do |page|
    Oga.parse_html(page).xpath("//article[@class='product_pod']").map do |pod|
      [pod.xpath("string(.//h3/a/@title)"), pod.xpath("string(.//p[@class='price_color'])").strip,
       last_word(pod.xpath("string(.//p[contains(@class,'star-rating')]/@class)"))]
    end
  end
}.freeze

QUOTE_SCRAPERS = {
  "fasthtmlparser find" => lambda do |page|
    FastHtmlParser.parse(page).find_all(Q.by(:div).has_class("quote")).map do |q|
      [q.find(Q.by(:span).has_class("text")).text, q.find(Q.by(:small).has_class("author")).text,
       q.find_all(Q.by(:a).has_class("tag")).map(&:text).join(",")]
    end
  end,
  "fasthtmlparser CSS" => lambda do |page|
    FastHtmlParser.parse(page).css("div.quote").map do |q|
      [q.css_first("span.text").text, q.css_first("small.author").text, q.css("a.tag").map(&:text).join(",")]
    end
  end,
  "fasthtmlparser XPath" => lambda do |page|
    FastHtmlParser.parse(page).xpath("//div[@class='quote']").map do |q|
      [q.xpath_value(".//span[@class='text']"), q.xpath_value(".//small[@class='author']"),
       q.xpath_values(".//a[@class='tag']").join(",")]
    end
  end,
  "Nokogiri HTML4 CSS" => lambda do |page|
    Nokogiri::HTML4(page).css("div.quote").map do |q|
      [q.at_css("span.text").text.strip, q.at_css("small.author").text.strip,
       q.css("a.tag").map { |a| a.text.strip }.join(",")]
    end
  end,
  "Nokogiri HTML5 CSS" => lambda do |page|
    Nokogiri::HTML5(page).css("div.quote").map do |q|
      [q.at_css("span.text").text.strip, q.at_css("small.author").text.strip,
       q.css("a.tag").map { |a| a.text.strip }.join(",")]
    end
  end,
  "Oga CSS" => lambda do |page|
    Oga.parse_html(page).css("div.quote").map do |q|
      [q.at_css("span.text").text.strip, q.at_css("small.author").text.strip,
       q.css("a.tag").map { |a| a.text.strip }.join(",")]
    end
  end
}.freeze

PARSERS = {
  "fasthtmlparser" => ->(p) { FastHtmlParser.parse(p) },
  "Nokogiri HTML4" => ->(p) { Nokogiri::HTML4(p) },
  "Nokogiri HTML5" => ->(p) { Nokogiri::HTML5(p) },
  "Oga" => ->(p) { Oga.parse_html(p) }
}.freeze

def check_same_records(name, page, scrapers)
  expected = nil
  scrapers.each do |label, scraper|
    records = scraper.call(page)
    raise "#{name}: #{label} found no records" if records.empty?

    expected ||= records
    next if records == expected

    diff = records.zip(expected).find { |a, b| a != b }
    raise "#{name}: #{label} gives other records than #{scrapers.keys.first}: #{diff.inspect}"
  end
  expected.size
end

def main(argv)
  seconds = (argv[0] || 2).to_f
  books = read("books/index.html")
  quotes = read("quotes/page1.html")
  laptops = read("webscraper/laptops.html")
  pages = [
    ["quotes, 11 KB", quotes],
    ["laptops, 38 KB", laptops],
    ["books, 51 KB", books],
    ["books x10, 510 KB", books * 10],
    ["books without `</li>` `</p>`", books.gsub("</li>", "").gsub("</p>", "")]
  ]

  n_books = check_same_records("books", books, BOOK_SCRAPERS)
  n_quotes = check_same_records("quotes", quotes, QUOTE_SCRAPERS)
  puts "every scraper returns the same records (books: #{n_books}, quotes: #{n_quotes})"
  puts
  jit = defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "YJIT on" : "no JIT"
  puts "Ruby #{RUBY_VERSION} (#{RUBY_PLATFORM}, #{jit}), Nokogiri #{Nokogiri::VERSION} " \
       "(libxml2 #{Nokogiri::VERSION_INFO.dig('libxml', 'loaded')}), Oga #{Oga::VERSION}; median time per call"
  puts

  puts "Parse a page:"
  puts
  puts "| Page | #{PARSERS.keys.join(' | ')} |"
  puts "|---|#{'---:|' * PARSERS.size}"
  pages.each do |label, page|
    cells = PARSERS.map do |name, parse|
      # Oga is slow on the big page: shorter measurements are enough
      measure(name == "Oga" ? [seconds / 2, 0.2].max : seconds) { parse.call(page) }
    end
    best = cells.min
    puts "| #{label} | #{cells.map { |c| c == best ? "**#{fmt(c)}**" : fmt(c) }.join(' | ')} |"
  end
  puts

  puts "Scrape a page (parse + extract the records):"
  puts
  puts "| Task | Time |"
  puts "|---|---:|"
  [["books", books, BOOK_SCRAPERS], ["quotes", quotes, QUOTE_SCRAPERS]].each do |name, page, scrapers|
    scrapers.each do |label, scraper|
      puts "| #{name}, #{label} | #{fmt(measure(seconds) { scraper.call(page) })} |"
    end
  end
end

main(ARGV)
