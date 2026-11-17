every scraper returns the same records (books: 20, quotes: 10)

Ruby 4.0.9 (x64-mingw-ucrt, no JIT), Nokogiri 1.19.7 (libxml2 2.13.9), Oga 3.5; median time per call

Parse a page:

| Page | fasthtmlparser | Nokogiri HTML4 | Nokogiri HTML5 | Oga |
|---|---:|---:|---:|---:|
| quotes, 11 KB | **456 μs** | 526 μs | 802 μs | 3.14 ms |
| laptops, 38 KB | **1.40 ms** | 1.79 ms | 2.38 ms | 10.11 ms |
| books, 51 KB | 1.54 ms | **1.45 ms** | 3.23 ms | 10.28 ms |
| books x10, 510 KB | 15.47 ms | **14.44 ms** | 31.01 ms | 107.99 ms |
| books without `</li>` `</p>` | 1.97 ms | **1.56 ms** | 2.83 ms | 9.62 ms |

Scrape a page (parse + extract the records):

| Task | Time |
|---|---:|
| books, fasthtmlparser find | 2.26 ms |
| books, fasthtmlparser CSS | 2.48 ms |
| books, fasthtmlparser XPath | 3.05 ms |
| books, Nokogiri HTML4 CSS | 3.13 ms |
| books, Nokogiri HTML4 XPath | 2.74 ms |
| books, Nokogiri HTML5 CSS | 4.57 ms |
| books, Nokogiri HTML5 XPath | 3.88 ms |
| books, Oga CSS | 13.86 ms |
| books, Oga XPath | 14.28 ms |
| quotes, fasthtmlparser find | 834 μs |
| quotes, fasthtmlparser CSS | 881 μs |
| quotes, fasthtmlparser XPath | 1.21 ms |
| quotes, Nokogiri HTML4 CSS | 1.32 ms |
| quotes, Nokogiri HTML5 CSS | 1.55 ms |
| quotes, Oga CSS | 4.66 ms |
