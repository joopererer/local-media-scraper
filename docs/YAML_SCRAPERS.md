# YAML 搜刮器插件规范（v1）

`scraper_core` 支持基于 YAML 语法的声明式搜刮器插件。无需编写 Dart 代码或重新编译程序，
通过定义规则文件即可接入任意网页、RESTful API 或本地模式提取器。

本文是 **插件格式的规范正本**。宿主应用（File Organizer 等）提供插件目录与设置界面，
本库只负责解析与执行规则。

---

## 一、 快速开始与文件存放位置

### 1. 插件目录
宿主应用把 `.yaml` / `.yml` 文件放进任意目录，交给 `YamlScraperLoader`：
```text
<plugins-dir>/
├── bilibili.yaml        # 样例：B 站视频 API 抓取
├── douban.yaml          # 样例：豆瓣电影网页抓取
├── bangumi.yaml         # 样例：Bangumi 番剧 API 抓取
├── tmdb.yaml            # 样例：TMDB 电影 API 抓取
└── my_custom.yaml       # 自定义插件
```

```dart
final loader = YamlScraperLoader(pluginsDirectory: Directory(pluginsDir));
final scrapers = await loader.loadScrapers();   // 读取全部插件
await loader.reload();                          // 手动重载
loader.watch().listen((list) { /* 目录变化后自动重载 */ });
```

### 2. 生效与重载
- 调用 `reload()` 立即重新扫描全部 `.yaml` / `.yml`。
- 监听 `watch()` 可在编辑器保存文件后自动重载（带防抖）。
- 单个文件解析失败只影响该文件，其余插件照常加载，错误通过 `onLog` 回调输出。
- 命令行验证：`dart run scraper_core:scraper_cli --plugin my_custom.yaml --file TEST-1.mp4 --verbose`

---

## 二、 完整 YAML 配置规范

```yaml
# ==============================================================================
# 1. 基础元信息 (必须)
# ==============================================================================
id: "my_scraper"                 # 唯一标识符 (英文字母、下划线)
name: "我的电影搜刮器"           # 界面显示的名称
description: "提取电影的年份与导演" # 功能简述
priority: 75                     # 优先级 (数值越大越早执行，建议 50-85)

# ==============================================================================
# 2. 触发与路由规则 (可选)
# ==============================================================================
# 限制生效的媒体类型：video / image / audio / document (不填则默认适用于全部媒体)
media_types:
  - "video"

# 该搜刮器专精的 Supertag。当文件带有这些 Supertag 时触发该搜刮器。
target_supertags:
  - "电影"
  - "Movie"

# 特征匹配正则表达式：针对文件名、源网页 URL 或当前标题进行匹配
# 匹配到的分组将在下文中作为 {1}, {2}... 或 match:1, match:2 使用
#
# ⚠️ 若用 | 块标量书写正则，请写成 pattern: |-（strip chomping）。
#    用 | 会把结尾换行保留进正则，末尾那一个分支就需要额外匹配一个 \n，
#    结果是该分支永远不命中，而前面的分支看起来完全正常。
pattern: 'tt(\d{7,8})|themoviedb\.org/movie/(\d+)'

# 命中特征正则后，自动为该文件打上的 Supertag 标签路径 (两阶段调度)
supertag_to_backfill:
  - "影视"
  - "电影"

# ==============================================================================
# 3. 动态配置项规范 (config_schema，可选)
# ==============================================================================
# 在应用设置界面自动生成专属设置控件，支持用户自定义 API Key、镜像源或代理。
config_schema:
  - key: "api_key"
    label: "服务 API Key"
    type: "password"             # 类型: string / password / url / boolean
    required: true
    description: "访问第三方平台必须的用户 API 密钥"
  - key: "base_url"
    label: "镜像站或反代地址"
    type: "url"
    default: "https://api.example.com"
    description: "网络受限时可自定义的反代服务器基准 URL"

# ==============================================================================
# 4. HTTP 请求配置 (可选，若不填则只针对本地文件名/输入文本提取)
# ==============================================================================
request:
  # 目标 URL 模板。支持微模板语法：
  # - {1}, {2}...：对应 pattern 正则匹配到的捕获组
  # - {input}：完整的文件名或输入 URL
  # - {config:key}：读取用户在 UI 中配置的参数
  # - 条件判断：{if {config:base_url}}{config:base_url}{else}https://api.example.com{/if}
  # - 回退兜底链：{1 ?? 2 ?? input}（优先取 1，为空则取 2，再为空则取输入原值）
  url_template: "{if {config:base_url}}{config:base_url}{else}https://api.example.com{/if}/search?q={1 ?? input}&key={config:api_key}"
  timeout_seconds: 10
  headers:
    User-Agent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    Accept: "application/json"

# ==============================================================================
# 4b. 多地址级联 request_urls (与 request 互斥，优先级更高)
# ==============================================================================
# 按顺序尝试每个地址，取第一个「HTTP 200 且通过正文校验」的响应；前一个失败
# (4xx/5xx/超时/正文被拒) 就换下一个。适合主站 + 备用站。
# request_urls:
#   - url: "{if {config:base_url}}{config:base_url}{else}https://www.example.com{/if}/{0}"
#     timeout_seconds: 10
#     headers:
#       Cookie: "age=verified"
#     # 正文必须包含其中「全部」关键字，否则视为失败（不区分大小写）
#     require_body_contains:
#       - "movie-panel"
#     # 正文只要包含任一关键字就视为失败（不区分大小写）
#     # 年龄确认页通常返回 HTTP 200，只能靠正文特征识别
#     reject_body_contains:
#       - "Age Verification"
#   - url: "https://mirror.example.com/search?q={0}&f=all"
#     timeout_seconds: 10

# ==============================================================================
# 5. 候选列表与二级深度自动挖掘 (items & detail_request，可选)
# ==============================================================================
# 当接口返回多条搜索匹配候选时提取列表，供用户核验弹窗交互选择；
# 若仅返回唯一候选且配置了 auto_drill_down_single: true，将自动进入二级深度挖掘请求。
#
# items.source 有两种写法：
#   - "json:..."  ：JSON 数组，每个元素一个候选（子规则用 json: 路径）
#   - "regex:..." ：HTML 分块正则，**每一处匹配**是一个候选（子规则用 regex:，
#                    或 `1`/`2` 取该分块的捕获组）
# items.filter 可选：用 pattern 的捕获组渲染成一个正则（如 {1}-{2}），
#   只保留命中它的候选，避免搜索结果首条不是目标（HTML 搜索页几乎必须写）。
items:
  source: "json:data.results"    # 或 'regex:<div class="item">[\s\S]*?</div>\s*</a></div>'
  title: "json:title"            # 或 'regex:<div class="video-title">(?:<strong>[^<]*</strong>)?\s*([^<]+)</div>'
  subtitle: "json:director"
  url: "json:detail_url"         # 或 'regex:<a href="([^"]+)"'
  cover: "json:poster"
  filter: '(?:^|[^A-Za-z0-9]){1}-{2}(?:[^0-9]|$)'   # 可选，仅保留真正匹配番号的候选

detail_request:
  url_template: "https://detail.example.com{url|raw}"
  # {url|raw} = 原样插入；HTML 里拿到的通常是 /v/xxx 这种站内相对路径，
  # 用 {url} 会被 URL 编码成 %2Fv%2Fxxx，请求会 404。
  auto_drill_down_single: true   # 当候选数量为 1 时，无需询问自动触发二级详情请求

# ==============================================================================
# 6. 字段提取规则列表 (fields)
# ==============================================================================
fields:
  # 提取标识码 (code)
  - key: "code"
    source: "match:1"            # 取正则第 1 捕获组
    confidence: 1.0              # 默认置信度 (用户可在设置页手动微调覆写)

  # 提取标题，并将此字段指定为文件建议标题
  - key: "title"
    source: "json:data.title"    # JSON 路径提取
    fallback: "json:original_title" # 主源为空时的备选回退源
    is_title: true               # 标为主标题建议 (可选，若 key 为 'title' 自动为 true)
    confidence: 0.95

  # 提取实体字段 (如导演、演员、片商)，entity_type 会创建关联实体
  - key: "director"
    source: "regex:导演:</span>\s*<a[^>]*>(.*?)</a>"  # 正则提取
    entity_type: "director"      # 实体类型：director / actress / studio / author 等
    confidence: 0.9

  # 提取数值字段
  - key: "year"
    source: "json:year"
    value_type: "number"
    confidence: 0.9

  # 提取封面或海报，作为资产预览图
  - key: "cover"
    source: "json:data.poster_url"
    # prefix 兼具 base URL 语义：值以 / 开头的相对路径会补上域名；
    # 值本身已是绝对 URL（https://… 或 //host/…）时不会重复拼接
    prefix: "https://image.example.com/w500"
    is_preview_image: true       # 标为海报/封面 (可选，若 key 为 'cover' 或 'poster' 自动为 true)
    confidence: 0.95

  # 静态常量
  - key: "country"
    source: "static:中国"
    confidence: 0.8

# ==============================================================================
# 7. 标签提取规则列表 (tags)
# ==============================================================================
tags:
  - "json:data.genres"           # 提取 JSON 列表作为动态标签
  - "regex:类型:</span>\s*(.*?)</p>" # 正则动态标签
  - "电影"                       # 静态单层标签
  - "影视 / 华语电影"             # 静态多级标签 (以 '/' 分割)
  - "影视 / 年份 / {year}"        # 支持字段插值的动态多级层级树标签
```

---

## 二·五、 多地址级联与正文校验（`request_urls`）

一个插件可以声明多个候选地址，引擎会按顺序尝试，**取第一个成功的响应**：

1. 请求失败（非 200、超时、异常）→ 试下一个地址；
2. `require_body_contains` 里任一关键字在正文中找不到 → 试下一个地址；
3. `reject_body_contains` 里任一关键字出现在正文中 → 试下一个地址；
4. 通过以上检查的正文即为本次抓取的解析对象。

关键字匹配不区分大小写，后续地址可以拥有各自独立的 `headers` 和 `timeout_seconds`。

> 年龄确认页、地区拦截页、Cloudflare 挑战页通常返回 **HTTP 200**，只靠状态码无法识别，
> 因此抓取受年龄验证保护的站点时请配置 `reject_body_contains`。

> 配置项默认值请用 `{if {config:key}}...{else}默认值{/if}`。`{config:key|默认值}`
> 这种写法**不被支持**，会被原样拼进 URL 导致请求失败。

---

## 三、 数据来源（`source` 语法详解）

在 `fields` 和 `tags` 中，`source` 字段指示系统如何从 HTTP 响应或文件名中提炼数据：

| 语法前缀 | 示例 | 说明 |
| :--- | :--- | :--- |
| `match:<N>` | `match:1` | 提取 `pattern` 正则表达式中的第 `N` 个括号捕获组（1-based）。 |
| `json:<path>` | `json:data.owner.name` | 针对 JSON 响应，用 `.` 连接层级路径（支持字典下钻）。 |
| `regex:<pattern>` | `regex:<title>(.*?)</title>` | 对网页 HTML 或原始文本执行正则提取。若包含捕获组则取第 1 组，否则取整体匹配。 |
| `static:<text>` | `static:2024` | 固定赋值，不依赖网络或文件名解析。 |
| `value_map:<name>` | `value_map:studios` | 值映射查表（**精确匹配**）。从 `pattern` 捕获组 1 提取键，在 `value_maps` 表中查找；不在表中则不返回该字段。 |
| `prefix_map:<name>` | `prefix_map:studios` | 值映射查表（**前缀匹配**）。从 `pattern` 捕获组 1 提取键，在 `value_maps` 表中查找；不在表中时返回键本身作为回退。 |

## 值映射表（`value_maps`）— 可选特性

用于将特定字符串前缀或代码映射到规范名称或实体。映射表的语法格式：

```yaml
value_maps:
  studios:                    # 映射表名（在 source 中作为 value_map:studios 或 prefix_map:studios 引用）
    ABC: { value: "ABC Studios Inc.", confidence: 0.98 }
    XYZ: { value: "XYZ Production", confidence: 0.96 }
  
  regions:                    # 另一个映射表示例
    SH: "中国 / 上海"
    BJ: "中国 / 北京"
```

**说明**：
- 映射表中的 **key** 必须大写；查询时系统自动转换为大写进行匹配。
- 每个条目的 **value** 可以是字符串（默认置信度 0.95），或含 `value` 与 `confidence` 字段的对象。
- 在 `fields` 中使用 `source: "value_map:studios"` 或 `source: "prefix_map:studios"`，系统自动从 pattern 正则捕获组 1 提取键，向该表查询。
- **匹配模式差异**：
  - `value_map:`：精确匹配，键不在表中时不返回该字段（严格模式）。
  - `prefix_map:`：前缀匹配，键不在表中时返回键本身作为回退值（宽松模式）。
- 两个可选的置信度字段 `confidence_known` 和 `confidence_unknown`（对两种匹配模式均有效）：
  - `confidence_known`：键在表中找到时使用该置信度（覆盖表中条目的置信度）。
  - `confidence_unknown`：键不在表中时使用该置信度（`prefix_map:` 回退时有效；`value_map:` 因不返回字段而无效）。

**示例**：

```yaml
fields:
  # 前缀匹配：未知片商代码也返回
  - key: "studio"
    source: "prefix_map:studios"
    entity_type: "studio"
    confidence_known: 0.95      # 找到映射时用该置信度
    confidence_unknown: 0.70    # 回落键本身时用该置信度
  
  # 精确匹配：只返回已知区域代码
  - key: "region"
    source: "value_map:regions"
    confidence_known: 0.95      # 找到映射时用该置信度
```

---

### 字段提取的已知限制

以下能力当前**不支持**，写插件时不要试图用正则硬绕，必要时先在插件仓库提需求：

| 限制 | 说明 |
| :--- | :--- |
| 单个 `regex:` 只取第一处匹配 | 页面上有多个演员 / 多个类别时，字段只能拿到第一个。字段值按 key 存储，也没有「一字段多值」的通道。 |
| `fields` 只有 `source` + `fallback` 两级 | 无法表达「主站解析 → 备用站解析 → 本地映射表」三级回退。常见做法是把多个站点的结构合并进同一条正则（用标记前缀做分支，共享一个捕获组）。 |
| `prefix_map:` / `value_map:` 只读捕获组 1 | 查询键固定取 `pattern` 的第 1 组，无法指定别的组。多分支正则必须让每个分支的「键」都落在组 1。 |
| `items:` 的 HTML 分块靠正则，不是真正的 DOM 解析 | `source` 用 `regex:` 时按「匹配一片 HTML」来分块（例如 `<div class="item">[\s\S]*?</a></div>`），嵌套层级深的站点写起来容易脆；`filter` 不写就可能把列表首条当成目标。 |
| 字段值无 `{config:...}` 模板 | `prefix` / `suffix` 是静态字符串，不能拼配置项。相对 URL 会由 `prefix` 补成绝对地址（已是绝对 URL 则不拼接），但域名无法跟随配置项变化，镜像站的封面/图片需要写死域名。 |
| 无「提取后处理」 | 没有 regex-replace、去后缀、拼接等后处理，裁剪标题后缀一类需求只能塞进正则本身。 |

---

## 四、 常见实战样例

### 样例 1：网页抓取（电影详情页，`movie_detail.yaml`）
根据文件名或 URL 中的编号前往详情页，抓取标题、导演、发行年份与封面。
下面的正则按**真实详情页结构**编写，演示 `match:` / `regex:` / `prefix:` / `entity_type` 组合：
```yaml
id: "movie_detail"
name: "Movie Detail 自定义搜刮器"
description: "根据编号前往详情页抓取标题、导演、年份与封面"
priority: 70
media_types:
  - "video"
target_supertags:
  - "电影"
pattern: 'movie\.example\.com/subject/(\d+)'
supertag_to_backfill:
  - "电影"
request:
  url_template: "https://movie.example.com/subject/{1}/"
  timeout_seconds: 10
fields:
  - key: "subject_id"
    source: "match:1"
    confidence: 1.0
  # <title>片名 (年份) - 站点</title>：去掉年份与站点后缀
  - key: "title"
    source: 'regex:<title>\s*(.+?)\s*\(\d{4}\)\s*-\s*[^<]*</title>'
    is_title: true
    confidence: 0.95
  # 详情页给的是相对路径，用 prefix 补域名
  - key: "cover"
    source: 'regex:<img[^>]+class="poster"[^>]+src="([^"]+)"'
    prefix: "https://movie.example.com"
    is_preview_image: true
    confidence: 0.95
  # 导演：<a rel="v:directedBy">NAME</a>
  - key: "director"
    source: 'regex:rel="v:directedBy">([^<]+)</a>'
    entity_type: "director"
    confidence: 0.95
  # 发行年份：<span class="year">(2021)</span>
  - key: "year"
    source: 'regex:<span class="year">\((\d{4})\)</span>'
    value_type: "number"
    confidence: 0.9
tags:
  - "电影"
  - "电影 / 导演 / {director}"
```

### 样例 2：网页搜索结果 → 详情页（`search_then_detail.yaml`）

搜索页没有 API 时，用 `items:` 的 `regex:` 分块 + `filter` 锁定目标，再自动深挖详情页：

```yaml
id: "search_then_detail"
name: "搜索页 → 详情页"
description: "先搜号，再进详情页抓标题、演员、封面"
priority: 60
pattern: '([A-Za-z]{2,6})[-_]?(\d{2,5})'
request_urls:
  - url: "https://site.example.com/search?q={1}-{2}"
    reject_body_contains: ["Age Verification"]
fields:
  - key: "title"
    source: 'regex:<strong class="current-title">([^<]+)</strong>'
    is_title: true
  - key: "actress"
    source: 'regex:<a class="actor-female"[^>]*>([^<]+)</a>'
    entity_type: "actress"
  - key: "cover"
    source: 'regex:<img class="video-cover" src="([^"]+)"'
    is_preview_image: true
items:
  source: 'regex:<div class="item">[\s\S]*?</div>\s*</a></div>'
  title: 'regex:<div class="video-title">(?:<strong>[^<]*</strong>)?\s*([^<]+)</div>'
  url: 'regex:<a href="([^"]+)"'
  cover: 'regex:<img[^>]+src="([^"]+)"'
  filter: '(?:^|[^A-Za-z0-9]){1}-{2}(?:[^0-9]|$)'
detail_request:
  url_template: "https://site.example.com{url|raw}"
  auto_drill_down_single: true
```

要点：
- `filter` 命中恰好 1 条候选 → 自动请求 `detail_request`，`fields` 在详情页正文上解析。
- `{url|raw}` 不编码，直接拼 `/v/xxx` 这类相对路径。

### 样例 3：Bilibili 视频 API 抓取 (`bilibili.yaml`)
根据 BV 号自动从 Bilibili 官方开放接口提取视频标题、UP 主与分区：
```yaml
id: "bilibili"
name: "Bilibili 视频刮削器"
description: "根据 BV 号抓取标题、UP 主、封面与分区标签"
priority: 75
target_supertags:
  - "视频"
  - "Bilibili"
pattern: 'bilibili\.com/video/(BV[a-zA-Z0-9]{10})|\b(BV[a-zA-Z0-9]{10})\b'
supertag_to_backfill:
  - "视频"
  - "Bilibili"
request:
  url_template: "https://api.bilibili.com/x/web-interface/view?bvid={1}"
  timeout_seconds: 10
fields:
  - key: "bvid"
    source: "match:1"
    confidence: 1.0
  - key: "title"
    source: "json:data.title"
    is_title: true
    confidence: 0.95
  - key: "author"
    source: "json:data.owner.name"
    entity_type: "author"
    confidence: 0.9
  - key: "cover"
    source: "json:data.pic"
    is_preview_image: true
    confidence: 0.9
  - key: "summary"
    source: "json:data.desc"
    confidence: 0.85
tags:
  - "json:data.tname"
  - "视频"
  - "Bilibili"
```

---


## 五、 如何测试与验证

### 1. 快速验证 YAML 语法
- 命令行：`dart run scraper_core:scraper_cli --plugin my_custom.yaml --file TEST-1.mp4 --verbose`
  - 若 YAML 缩进或类型有误，会在 stderr 输出具体错误并退出码 2。
  - 解析成功时会打印 JSON：`backfillSupertags` / `proposedTitle` / `previewImageUrl` / `runs`。
- 在宿主应用里，调用 `YamlScraperLoader.reload()` 后检查插件列表中是否出现你的插件及其名称、优先级。

### 2. 测试执行搜刮
1. **准备输入**：一个文件名（如 `ABC-123.mkv`、`BV1xx411c7mD.mp4`）或一个来源 URL。
2. **触发刮削**：调用 `ScraperPlanner.plan(ScrapeInput(...))`，或用 CLI 的 `--file` / `--url`。
3. **观察结果**：
   - `plan.proposedTitle` / `plan.previewImageUrl` 是最高优先级非空结果。
   - `plan.runs[].result.fields` 是按 `fields` 规则抽出的字段。
   - `plan.runs[].result.tags` 是按 `tags` 规则生成的标签路径。
   - `plan.backfill` 是命中了 `pattern` 后需要回填的 supertag。

### 3. 调整优先级顺序
- 通过 `ScraperSettings(priorityOverrides: {'my_scraper': 80})` 覆写优先级，或给插件写更大的 `priority`。
- 当多个刮削器命中同一个文件时，优先级数值更高的先执行，其标题/封面优先被采用。

### 4. 已知限制（v1.1）
- 每个字段只取单个值；多值字段需拆成多个 field 规则。
- `request_urls` 级联只在第一个通过守卫的地址上继续。
- `value_map:` 固定读取 `pattern` 的第 1 个捕获组。
- JSON 路径的 `items[0]` 索引仅对 JSON 有效，不作用于 HTML。
- `prefix:` 不能包含模板占位符。
- HTML 候选分块靠正则而非 DOM；搜索页建议配 `items.filter`。
- 「搜索页 → 详情页」两级抓取目前只在 `auto_drill_down_single` 生效（候选恰好 1 条）时自动执行；多候选需在核验弹窗里选。
- 暂不提供抽出后处理（大小写转换、拆分等）。
