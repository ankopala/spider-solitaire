-- src/persist.lua —— 设置的序列化与落盘（纯逻辑，不引用 love）
--
-- 【为什么需要一个文件】
--   ctx.settings 只是 main.lua 在 love.load 里新建的一个 table，活在内存里。
--   关掉游戏这个 table 就没了，下次启动会重新执行默认值 —— 玩家改过的难度、
--   提示方式一次都不会留下。这叫"不落盘"。
--
-- 【为什么不直接调 love.filesystem】
--   本文件的 encode / decode 是纯字符串处理，能在终端跑测试；
--   真正读写由调用方注入一个 store：
--       store = { read = fn() -> string|nil,  write = fn(s) }
--   main.lua 里那两行就是 love.filesystem.read / write。
--   这样测试可以塞一个"内存文件"，不必启动 LÖVE。
--
-- 【格式】极简的 key=value，一行一条：
--     difficulty=2
--     hintMode=button
--   不用 JSON：字段就两个，手写解析比引一个库划算得多。
--
-- ⚠ 解码必须【宽容】：文件可能被手改坏、被旧版本写成别的值、甚至被截断。
--   任何一个字段不认识都退回默认值，绝不能让游戏因为读设置而崩掉。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local M = {}

M.FILE = "settings.txt"

-- 默认值集中在这里：改默认难度只改这一处
local DEFAULT_DIFFICULTY = 4
local DEFAULT_HINT_MODE  = "auto"

local VALID_DIFFICULTY = { [1] = true, [2] = true, [4] = true }
local VALID_HINT_MODE  = { auto = true, button = true }

-- 所有"按难度分开"的统计都走这张难度表：最高分 / 局数 / 胜局。
-- 为什么不共用一个数：1 花色能打到 1200，4 花色打 500 都费劲。
-- 混在一起比，高难度的纪录永远刷不出来，这个功能就等于没做。
local DIFFICULTIES = { 1, 2, 4 }

-- best / games / wins 三张表共用这个构造器：难度 -> 0
local function emptyByDiff()
  local out = {}
  for i = 1, #DIFFICULTIES do
    out[DIFFICULTIES[i]] = 0
  end
  return out
end

-- 注意：每次都要造一张新表。如果做成模块级共享表，
-- 两次 defaults() 会指向同一块内存，改一个地方全都变。
function M.defaults()
  return {
    difficulty = DEFAULT_DIFFICULTY,
    hintMode   = DEFAULT_HINT_MODE,
    best       = emptyByDiff(),
    games      = emptyByDiff(),   -- 已结算的局数（赢 + 认输）
    wins       = emptyByDiff(),   -- 其中的胜局数
  }
end

-- 把一个设置表规范化（顺手挡掉非法值）
local function sanitize(s)
  local diff = tonumber(s and s.difficulty)
  if not VALID_DIFFICULTY[diff] then diff = DEFAULT_DIFFICULTY end

  local mode = s and s.hintMode
  if not VALID_HINT_MODE[mode] then mode = DEFAULT_HINT_MODE end

  return diff, mode
end

-- 计数表规范化：不是表、缺键、负数、非数字，一律按 0 算。
-- 三张表规则相同，所以共用一个函数（第二个参数是表名，只为报错时可读）。
local function sanitizeCountTable(s, name)
  local out = emptyByDiff()
  local src = s and s[name]
  if type(src) ~= "table" then return out end

  for i = 1, #DIFFICULTIES do
    local d = DIFFICULTIES[i]
    local n = tonumber(src[d])
    if n and n > 0 then out[d] = math.floor(n) end
  end
  return out
end

function M.encode(settings)
  local diff, mode = sanitize(settings)
  local best  = sanitizeCountTable(settings, "best")
  local games = sanitizeCountTable(settings, "games")
  local wins  = sanitizeCountTable(settings, "wins")

  -- 别写成 11 个占位符的 string.format：加一个字段就要数一遍参数，
  -- 而且顺序错位这种 bug 不会报错，只会把数字写到别的键上。
  local lines = {}
  lines[#lines + 1] = string.format("difficulty=%d", diff)
  lines[#lines + 1] = string.format("hintMode=%s", mode)

  for i = 1, #DIFFICULTIES do
    local d = DIFFICULTIES[i]
    lines[#lines + 1] = string.format("best%d=%d", d, best[d])
  end
  for i = 1, #DIFFICULTIES do
    local d = DIFFICULTIES[i]
    lines[#lines + 1] = string.format("games%d=%d", d, games[d])
    lines[#lines + 1] = string.format("wins%d=%d", d, wins[d])
  end

  return table.concat(lines, "\n") .. "\n"
end

-- 解析文件内容。任何异常都退回默认值，不抛错。
function M.decode(text)
  local out = M.defaults()
  if type(text) ~= "string" then return out end

  for line in string.gmatch(text, "[^\r\n]+") do
    -- ⚠ for 的循环变量在 Lua 5.4+ 是 const，不能就地改写 → 用 body 接一下
    local body = string.gsub(line, "#.*$", "")    -- 允许行尾注释
    -- 允许 "key = value" / 前后空格，手改起来不用太小心
    local k, v = string.match(body, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if k and v then
      if k == "difficulty" then
        local n = tonumber(v)
        if VALID_DIFFICULTY[n] then out.difficulty = n end
      elseif k == "hintMode" then
        if VALID_HINT_MODE[v] then out.hintMode = v end
      elseif k == "best1" or k == "best2" or k == "best4" then
        -- "best1" 的第 5 个字符起就是难度数字
        local d = tonumber(string.sub(k, 5))
        local n = tonumber(v)
        -- 负数没有意义；"abc" tonumber 得到 nil，一起挡掉
        if VALID_DIFFICULTY[d] and n and n >= 0 then
          out.best[d] = math.floor(n)
        end
      elseif k == "games1" or k == "games2" or k == "games4" then
        -- "games" 占 5 个字符，难度在第 6 位
        local d = tonumber(string.sub(k, 6))
        local n = tonumber(v)
        if VALID_DIFFICULTY[d] and n and n >= 0 then
          out.games[d] = math.floor(n)
        end
      elseif k == "wins1" or k == "wins2" or k == "wins4" then
        -- "wins" 占 4 个字符，难度在第 5 位
        local d = tonumber(string.sub(k, 5))
        local n = tonumber(v)
        if VALID_DIFFICULTY[d] and n and n >= 0 then
          out.wins[d] = math.floor(n)
        end
      end
      -- 不认识的键直接忽略：以后加字段时，旧存档不会被判成坏文件
    end
  end

  -- 手改文件可能写出 wins=99 / games=1 这种自相矛盾的组合。
  -- 夹一次，界面上就不会出现 "won 99/1 (9900%)"。
  for i = 1, #DIFFICULTIES do
    local d = DIFFICULTIES[i]
    if out.wins[d] > out.games[d] then out.wins[d] = out.games[d] end
  end

  return out
end

-- store 可选；没有 store（或读失败）就拿默认值。
-- 读文件本身用 pcall 包住：权限问题、目录不存在都不该让游戏起不来。
function M.load(store)
  if not store or not store.read then return M.defaults() end

  local ok, text = pcall(store.read)
  if not ok or type(text) ~= "string" then return M.defaults() end

  return M.decode(text)
end

-- 落盘。返回 true/false；失败也不抛错（写不进去不该影响这一局游戏）。
function M.save(settings, store)
  if not store or not store.write then return false end
  local ok = pcall(store.write, M.encode(settings))
  return ok
end

-- ===== 最高分（M11）=====
-- 记一次通关成绩。返回 (当前最高分, 是否破纪录)。
-- 只该在"这局真的赢了"时调用 —— 认输、中途退出都不算。
-- 放在这里而不是 playing.lua，是为了能在终端直接断言，不必启动 LÖVE。
function M.recordBest(settings, difficulty, score)
  local d = tonumber(difficulty)
  local s = tonumber(score)
  if type(settings) ~= "table" or not VALID_DIFFICULTY[d] or not s then
    return 0, false
  end

  -- 老存档（或手搓的 settings）可能根本没有 best 这张表
  if type(settings.best) ~= "table" then settings.best = emptyByDiff() end

  local prev = tonumber(settings.best[d]) or 0
  s = math.floor(s)
  if s > prev then
    settings.best[d] = s
    return s, true
  end
  return prev, false
end

-- ===== 局数与胜局（M12）=====
-- 口径（用户定的）：
--   赢    → games +1、wins +1
--   认输  → games +1（Resign 面板里选 New deal 那一刻）
--   Esc 回菜单 / Restart this deal / R 重发 → 都不计
--
-- ⚠ 已知漏洞（有意保留）：玩家可以用 Restart 或 Esc 逃避失败记录，
--   所以这个胜率是"你选择结算的那些局"里的胜率，不是"开局数胜率"。
--   不要偷偷把 Restart 记成输 —— 那是在玩家无感知的情况下改口径。
function M.recordResult(settings, difficulty, isWin)
  local d = tonumber(difficulty)
  if type(settings) ~= "table" or not VALID_DIFFICULTY[d] then
    return 0, 0
  end

  if type(settings.games) ~= "table" then settings.games = emptyByDiff() end
  if type(settings.wins)  ~= "table" then settings.wins  = emptyByDiff() end

  local games = (tonumber(settings.games[d]) or 0) + 1
  settings.games[d] = games
  if isWin then
    settings.wins[d] = (tonumber(settings.wins[d]) or 0) + 1
  end

  return games, (tonumber(settings.wins[d]) or 0)
end

-- 给界面取数：返回 best, wins, games, pct。
-- games == 0 时 pct 是 nil（不是 0）—— 调用方据此决定画不画这一行，
-- 这样永远不会出现 "0/0" 或 "nan%"。
function M.statsFor(settings, difficulty)
  local d = tonumber(difficulty)
  local best, wins, games = 0, 0, 0

  if type(settings) == "table" and VALID_DIFFICULTY[d] then
    local b = settings.best  and tonumber(settings.best[d])  or 0
    local g = settings.games and tonumber(settings.games[d]) or 0
    local w = settings.wins  and tonumber(settings.wins[d])  or 0

    if b > 0 then best = math.floor(b) end
    if g > 0 then games = math.floor(g) end
    if w > 0 then wins = math.floor(w) end
  end

  if wins > games then wins = games end

  local pct = nil
  if games > 0 then
    -- 整数四舍五入。不用 "%.0f%%"：万一哪天把 0/0 传进来，
    -- 那个分支会打印出 "nan%"，而这里根本走不到。
    pct = math.floor(wins * 100 / games + 0.5)
    if pct < 0 then pct = 0 elseif pct > 100 then pct = 100 end
  end

  return best, wins, games, pct
end

return M
