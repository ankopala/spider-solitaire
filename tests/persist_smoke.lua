-- tests/persist_smoke.lua —— M10「设置落盘」的序列化与容错（终端验证，不需要 LÖVE）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/persist_smoke.lua
--
-- 这里的每一条"坏输入"都是真会发生的：玩家手改文件、旧版本写下的值、
-- 写到一半被 kill 掉留下的半行。读设置绝不能因为这些让游戏起不来。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local persist = require("src.persist")

-- ===== 断言小工具 =====
local passed, failed = 0, 0

local function check(name, cond)
  if cond then
    passed = passed + 1
    print("  [PASS] " .. name)
  else
    failed = failed + 1
    print("  [FAIL] " .. name)
  end
end

local function section(title)
  print("")
  print(title)
  print(string.rep("-", 62))
end

-- 内存里的"假文件"：和 main.lua 里的 fileStore 形状完全一样
local function fakeStore(initial)
  local store = { text = initial, writes = 0 }
  store.read = function() return store.text end
  store.write = function(s) store.text = s; store.writes = store.writes + 1; return true end
  return store
end

-- ===== 1. 编码 =====
section("1. encode")

-- M11 起 5 行（两个设置 + 三个难度的最高分），M12 再加 6 行（局数 / 胜局）
local function enc(diff, mode, b1, b2, b4, g1, w1, g2, w2, g4, w4)
  local lines = {}
  lines[#lines + 1] = string.format("difficulty=%d", diff)
  lines[#lines + 1] = string.format("hintMode=%s", mode)

  local bests = { b1, b2, b4 }
  local diffs = { 1, 2, 4 }
  for i = 1, 3 do
    lines[#lines + 1] = string.format("best%d=%d", diffs[i], bests[i] or 0)
  end

  local games = { g1, g2, g4 }
  local wins  = { w1, w2, w4 }
  for i = 1, 3 do
    lines[#lines + 1] = string.format("games%d=%d", diffs[i], games[i] or 0)
    lines[#lines + 1] = string.format("wins%d=%d",  diffs[i], wins[i]  or 0)
  end

  return table.concat(lines, "\n") .. "\n"
end

check("默认设置编成 11 行 key=value",
  persist.encode({ difficulty = 4, hintMode = "auto" }) == enc(4, "auto"))

check("1 花色 + button",
  persist.encode({ difficulty = 1, hintMode = "button" }) == enc(1, "button"))

check("非法难度退回 4",
  persist.encode({ difficulty = 3, hintMode = "auto" }) == enc(4, "auto"))

check("非法提示方式退回 auto",
  persist.encode({ difficulty = 2, hintMode = "sometimes" }) == enc(2, "auto"))

check("空表也能编出完整 11 行",
  persist.encode({}) == enc(4, "auto"))

check("带最高分时按难度写出去",
  persist.encode({ difficulty = 1, hintMode = "auto",
                   best = { [1] = 1200, [2] = 800, [4] = 500 } })
    == enc(1, "auto", 1200, 800, 500))

check("最高分里的负数 / 字母按 0 写",
  persist.encode({ difficulty = 1, hintMode = "auto",
                   best = { [1] = -5, [2] = "abc" } })
    == enc(1, "auto", 0, 0, 0))

-- ===== 2. 解码：正常 =====
section("2. decode：正常输入")

local d1 = persist.decode("difficulty=2\nhintMode=button\n")
check("读回难度 2", d1.difficulty == 2)
check("读回 button", d1.hintMode == "button")

local d2 = persist.decode("difficulty = 1\r\nhintMode = auto\r\n")
check("容忍空格和 CRLF",
  d2.difficulty == 1 and d2.hintMode == "auto")

local d3 = persist.decode("# my settings\ndifficulty=2   # 中等\nhintMode=button\n")
check("容忍注释行与行尾注释",
  d3.difficulty == 2 and d3.hintMode == "button")

local d4 = persist.decode("hintMode=button\ndifficulty=4\n")
check("字段顺序无关", d4.difficulty == 4 and d4.hintMode == "button")

-- ===== 3. 解码：坏输入（重点）=====
section("3. decode：坏输入一律退回默认值")

local D = persist.defaults()
check("默认值是 4 花色 + auto", D.difficulty == 4 and D.hintMode == "auto")

local e1 = persist.decode("")
check("空文件 → 默认值", e1.difficulty == 4 and e1.hintMode == "auto")

local e2 = persist.decode(nil)
check("nil → 默认值", e2.difficulty == 4 and e2.hintMode == "auto")

local e3 = persist.decode("difficulty=abc\nhintMode=button\n")
check("难度写成字母 → 只退回难度，其余照读",
  e3.difficulty == 4 and e3.hintMode == "button")

local e4 = persist.decode("difficulty=0\nhintMode=nope\n")
check("越界难度 / 未知模式 → 全退回默认",
  e4.difficulty == 4 and e4.hintMode == "auto")

local e5 = persist.decode("garbage without equals sign\n\n\n")
check("整行没有等号 → 默认值", e5.difficulty == 4 and e5.hintMode == "auto")

local e6 = persist.decode("difficulty=2\nhintMo")     -- 写入被中断，最后半行
check("被截断的半行忽略，前面读到的仍然生效",
  e6.difficulty == 2 and e6.hintMode == "auto")

local e7 = persist.decode("unknownKey=42\ndifficulty=1\n")
check("不认识的键忽略，不影响其它字段",
  e7.difficulty == 1 and e7.hintMode == "auto")

-- ===== 4. 往返 =====
section("4. encode → decode 往返")

for _, case in ipairs({
  { difficulty = 1, hintMode = "auto" },
  { difficulty = 2, hintMode = "button" },
  { difficulty = 4, hintMode = "auto" },
}) do
  local back = persist.decode(persist.encode(case))
  check(string.format("%d 花色 + %s 往返不变",
    case.difficulty, case.hintMode),
    back.difficulty == case.difficulty and back.hintMode == case.hintMode)
end

-- ===== 5. load / save =====
section("5. load / save 与 store 注入")

local st = fakeStore(nil)
check("没有存档时 load 返回默认值",
  (function()
    local s = persist.load(st)
    return s.difficulty == 4 and s.hintMode == "auto"
  end)())

st.text = "difficulty=1\nhintMode=button\n"
check("有存档时 load 读出来", (function()
  local s = persist.load(st)
  return s.difficulty == 1 and s.hintMode == "button"
end)())

check("save 会写一次", persist.save({ difficulty = 2, hintMode = "button" }, st) == true
  and st.writes == 1)
check("写进去的内容能被 load 读回", (function()
  local s = persist.load(st)
  return s.difficulty == 2 and s.hintMode == "button"
end)())

-- 没有 store：不崩，返回默认值 / false
check("load 不传 store → 默认值", persist.load(nil).difficulty == 4)
check("save 不传 store → false", persist.save({ difficulty = 1 }, nil) == false)

-- read / write 抛错：游戏必须照常起来
local brokenRead = { read = function() error("permission denied") end }
check("read 抛错 → 默认值，不往外抛",
  (function()
    local ok, s = pcall(persist.load, brokenRead)
    return ok and s.difficulty == 4 and s.hintMode == "auto"
  end)())

local brokenWrite = { write = function() error("disk full") end }
check("write 抛错 → 返回 false，不往外抛",
  (function()
    local ok, ret = pcall(persist.save, { difficulty = 2 }, brokenWrite)
    return ok and ret == false
  end)())

-- ===== 6. 只读：load 不改传进来的设置表 =====
section("6. load 不会回头改输入")

local src = { difficulty = 2, hintMode = "button" }
persist.encode(src)
persist.decode(persist.encode(src))
check("encode/decode 不改原表",
  src.difficulty == 2 and src.hintMode == "button")
check("encode 不会给原表补一张 best 表", src.best == nil)

-- ===== 7. 最高分（M11）=====
section("7. 最高分：recordBest 与兼容性")

local rb = persist.defaults()
check("全新设置三个难度都是 0",
  rb.best[1] == 0 and rb.best[2] == 0 and rb.best[4] == 0)

local v1, new1 = persist.recordBest(rb, 4, 820)
check("首次记 820 → 破纪录", v1 == 820 and new1 == true and rb.best[4] == 820)

local v2, new2 = persist.recordBest(rb, 4, 700)
check("再记 700 → 不算破纪录，表不变",
  v2 == 820 and new2 == false and rb.best[4] == 820)

local v3, new3 = persist.recordBest(rb, 4, 900)
check("再记 900 → 刷新", v3 == 900 and new3 == true and rb.best[4] == 900)

local v4, new4 = persist.recordBest(rb, 1, 1200)
check("难度 1 独立记，不影响难度 4",
  v4 == 1200 and new4 == true and rb.best[1] == 1200 and rb.best[4] == 900)

local v5, new5 = persist.recordBest(rb, 3, 999)
check("非法难度（3）→ 不记", v5 == 0 and new5 == false)

-- 老存档只有两行：best 必须是 0，而不是 nil
local old = persist.decode("difficulty=2\nhintMode=button\n")
check("旧存档（2 行）读出来 best 全 0",
  old.best[1] == 0 and old.best[2] == 0 and old.best[4] == 0)

local rt = persist.decode(persist.encode(rb))
check("最高分能往返", rt.best[1] == 1200 and rt.best[4] == 900 and rt.best[2] == 0)

local dirty = persist.decode("best4=-5\nbest2=abc\nbest1=777\n")
check("负数 / 字母忽略，合法值照读",
  dirty.best[1] == 777 and dirty.best[2] == 0 and dirty.best[4] == 0)

local cut = persist.decode("best1=650\nbest4=")
check("半行 best4= 忽略，best1 仍生效",
  cut.best[1] == 650 and cut.best[4] == 0)

-- settings 里根本没有 best 这张表（手搓的，或更老的结构）
local naked = { difficulty = 4, hintMode = "auto" }
local v6, new6 = persist.recordBest(naked, 4, 500)
check("settings 没有 best 表时自动补出来",
  v6 == 500 and new6 == true and naked.best[4] == 500)

check("settings 为 nil → 0, false，不崩", (function()
  local a, b = persist.recordBest(nil, 4, 500)
  return a == 0 and b == false
end)())

check("decode 出来的 best 是独立新表", (function()
  local x = persist.decode("")
  local y = persist.decode("")
  x.best[1] = 999
  return y.best[1] == 0
end)())

-- ===== 8. 局数与胜局（M12）=====
section("8. 局数与胜局：recordResult / statsFor")

local rs = persist.defaults()
check("全新设置三个难度局数都是 0",
  rs.games[1] == 0 and rs.games[2] == 0 and rs.games[4] == 0
  and rs.wins[1] == 0 and rs.wins[2] == 0 and rs.wins[4] == 0)

local rg1, rw1 = persist.recordResult(rs, 4, true)
check("赢一局 → games 1 / wins 1", rg1 == 1 and rw1 == 1)

local rg2, rw2 = persist.recordResult(rs, 4, false)
check("认输一局 → games 2 / wins 仍 1", rg2 == 2 and rw2 == 1)

local rg3, rw3 = persist.recordResult(rs, 1, true)
check("难度 1 独立记，不影响难度 4",
  rg3 == 1 and rw3 == 1 and rs.games[4] == 2)

check("非法难度 → 0, 0", (function()
  local a, b = persist.recordResult(rs, 3, true)
  return a == 0 and b == 0
end)())

check("settings 为 nil → 0, 0，不崩", (function()
  local a, b = persist.recordResult(nil, 4, true)
  return a == 0 and b == 0
end)())

check("settings 没有 games 表时自动补出来", (function()
  local naked = { difficulty = 4, hintMode = "auto" }
  persist.recordResult(naked, 4, true)
  return naked.games[4] == 1 and naked.wins[4] == 1
end)())

-- 旧存档只有 5 行：新表必须是 0，而不是 nil
local old5 = persist.decode("difficulty=2\nhintMode=auto\nbest1=0\nbest2=0\nbest4=0\n")
check("旧 5 行存档读出来 games / wins 全 0",
  old5.games[1] == 0 and old5.games[4] == 0
  and old5.wins[1] == 0 and old5.wins[4] == 0)

check("encode 写出 11 行", (function()
  local text = persist.encode(persist.defaults())
  local n = 0
  for _ in string.gmatch(text, "[^\r\n]+") do n = n + 1 end
  return n == 11
end)())

check("局数 / 胜局能往返", (function()
  local back = persist.decode(persist.encode(rs))
  return back.games[4] == 2 and back.wins[4] == 1
     and back.games[1] == 1 and back.wins[1] == 1
end)())

-- 手改文件写出自相矛盾的组合
local lie = persist.decode("games4=1\nwins4=99\n")
check("wins > games 时被夹到 games", lie.games[4] == 1 and lie.wins[4] == 1)

local negCount = persist.decode("games4=-3\nwins4=abc\n")
check("负数 / 字母计数忽略", negCount.games[4] == 0 and negCount.wins[4] == 0)

-- 胜率：整数四舍五入，0 局必须是 nil 而不是 0 或 nan
check("0 局 → pct 是 nil", (function()
  local _, _, _, pct = persist.statsFor(persist.defaults(), 4)
  return pct == nil
end)())

local oneOfThree = { difficulty = 4, best = { [4] = 0 },
                     games = { [4] = 3 }, wins = { [4] = 1 } }
local _, _, _, p13 = persist.statsFor(oneOfThree, 4)
check("1/3 → 33%", p13 == 33)

oneOfThree.wins[4] = 2
local _, _, _, p23 = persist.statsFor(oneOfThree, 4)
check("2/3 → 67%（四舍五入，不是截断成 66）", p23 == 67)

oneOfThree.wins[4] = 3
local _, _, _, p33 = persist.statsFor(oneOfThree, 4)
check("3/3 → 100%", p33 == 100)

local allLost = { difficulty = 4, best = { [4] = 0 },
                  games = { [4] = 12 }, wins = { [4] = 0 } }
local lb, lw, lg, lp = persist.statsFor(allLost, 4)
check("全输：best 0 / wins 0 / games 12 / 0%",
  lb == 0 and lw == 0 and lg == 12 and lp == 0)

check("statsFor 遇到 nil settings 也不崩", (function()
  local b, w, g, p = persist.statsFor(nil, 4)
  return b == 0 and w == 0 and g == 0 and p == nil
end)())

check("encode 不会给原表补 games 表", (function()
  local src2 = { difficulty = 1, hintMode = "auto" }
  persist.encode(src2)
  return src2.games == nil and src2.wins == nil
end)())

-- ===== 汇总 =====
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
