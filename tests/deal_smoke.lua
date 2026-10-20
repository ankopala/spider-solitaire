-- tests/deal_smoke.lua —— M1 终端验证脚本（发牌纯逻辑）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/deal_smoke.lua        # 默认难度 4
--   /opt/homebrew/bin/lua tests/deal_smoke.lua 1      # 难度 1
--   /opt/homebrew/bin/lua tests/deal_smoke.lua 0      # 1/2/4 三种难度都跑
--
-- 本脚本不依赖 LÖVE，用普通 Lua 解释器即可运行。

-- 修正 package.path：无论从哪里调用，都把「项目根目录」加入搜索路径，
-- 使 require("src.deck") 与 LÖVE 里的写法完全一致。
local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local deck = require("src.deck")
local game = require("src.game")

-- ===== 显示用映射 =====
local SUIT_LETTER = { spades = "S", hearts = "H", diamonds = "D", clubs = "C" }
local RANK_TEXT = {
  "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
}

local function cardText(c)
  -- faceUp 的牌不加后缀；背面牌加 * 提示
  return RANK_TEXT[c.rank] .. (SUIT_LETTER[c.suit] or "?") .. (c.faceUp and "" or "*")
end

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

-- ===== 跑一局：打印 + 断言 =====
local function runOne(difficulty)
  math.randomseed(os.time() + difficulty)
  local g = deck.dealNewGame(difficulty, math.random)

  print("")
  print(string.rep("=", 60))
  print(string.format("Spider deal smoke test    difficulty = %d", difficulty))
  print(string.rep("=", 60))
  for i = 1, 10 do
    local col = g.tableau[i]
    local top = col[#col]
    print(string.format("  col %2d   count=%d   top=%-4s   %s",
      i, #col, cardText(top), top.faceUp and "faceUp" or "DOWN"))
  end
  print(string.format("  stock    count=%d", #g.stock))
  print(string.rep("-", 60))

  -- 收集总张数
  local dealt = 0
  for i = 1, 10 do
    dealt = dealt + #g.tableau[i]
  end
  local total = dealt + #g.stock

  check("总牌数 = 104", total == 104)
  check("已发 54 张", dealt == 54)
  check("stock = 50", #g.stock == 50)

  -- 每列张数
  local expectCounts = { 6, 6, 6, 6, 5, 5, 5, 5, 5, 5 }
  local countsOK = true
  for i = 1, 10 do
    if #g.tableau[i] ~= expectCounts[i] then countsOK = false end
  end
  check("每列张数 = 6,6,6,6,5,5,5,5,5,5", countsOK)

  -- 每列仅顶牌 faceUp
  local faceUpOK = true
  for i = 1, 10 do
    local col = g.tableau[i]
    for j = 1, #col - 1 do
      if col[j].faceUp then faceUpOK = false end
    end
    if not col[#col].faceUp then faceUpOK = false end
  end
  check("每列仅顶牌 faceUp", faceUpOK)

  -- 遍历所有牌（tableau + stock）的辅助
  local function forEachCard(fn)
    for i = 1, 10 do
      for _, c in ipairs(g.tableau[i]) do fn(c) end
    end
    for _, c in ipairs(g.stock) do fn(c) end
  end

  -- 每个 rank 出现 8 次
  local rankCount = {}
  for r = 1, 13 do rankCount[r] = 0 end
  forEachCard(function(c) rankCount[c.rank] = rankCount[c.rank] + 1 end)
  local ranksOK = true
  for r = 1, 13 do
    if rankCount[r] ~= 8 then ranksOK = false end
  end
  check("每个 rank 各出现 8 次", ranksOK)

  -- 花色分布符合难度
  local suitCount = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 }
  forEachCard(function(c) suitCount[c.suit] = suitCount[c.suit] + 1 end)

  local expectSuit
  if difficulty == 1 then
    expectSuit = { spades = 104, hearts = 0, diamonds = 0, clubs = 0 }
  elseif difficulty == 2 then
    expectSuit = { spades = 52, hearts = 52, diamonds = 0, clubs = 0 }
  else
    expectSuit = { spades = 26, hearts = 26, diamonds = 26, clubs = 26 }
  end
  local suitOK = true
  for s, n in pairs(expectSuit) do
    if suitCount[s] ~= n then suitOK = false end
  end
  check("花色分布符合难度", suitOK)

  -- stock 内全部 faceUp = false
  local stockDownOK = true
  for _, c in ipairs(g.stock) do
    if c.faceUp then stockDownOK = false end
  end
  check("stock 内全部 faceUp = false", stockDownOK)

  -- 无重复牌对象（防止同一张牌被同时放进两处的引用 bug）
  local seen = {}
  local uniqueCount = 0
  forEachCard(function(c)
    local key = tostring(c)
    if not seen[key] then
      seen[key] = true
      uniqueCount = uniqueCount + 1
    end
  end)
  check("无重复牌对象（104 个唯一引用）", uniqueCount == 104)
end

-- ===== 种子与洗牌确定性（M12）=====
print("")
print(string.rep("=", 60))
print("M12: seed determinism")
print(string.rep("=", 60))

-- 测试用的确定性随机源（线性同余）。与 LÖVE 的生成器无关 ——
-- 这里要证明的是「给定同一串 rng 输出，洗牌必产生同一牌局」，
-- 至于 love.math.newRandomGenerator 跨进程是否稳定，靠探针另测。
local function makeRng(seed)
  local s = seed % 2147483647
  if s <= 0 then s = s + 2147483646 end
  return function(n)
    s = (s * 16807) % 2147483647
    return (s % n) + 1
  end
end

-- rng 调用形状：一局固定 103 次，参数从 104 递减到 2。
-- 这道断言是护栏：以后谁在发牌路径里多加一次随机调用，所有旧种子都会变形。
local args = {}
local inner = makeRng(1000)
deck.dealNewGame(4, function(n)
  args[#args + 1] = n
  return inner(n)
end)

check("一局固定调用 rng 103 次", #args == 103)
check("第一次传 104、最后一次传 2", args[1] == 104 and args[#args] == 2)

local strictlyDown = true
for i = 2, #args do
  if args[i] ~= args[i - 1] - 1 then strictlyDown = false end
end
check("参数严格递减（104, 103, ..., 2）", strictlyDown)

-- 同种子 → 同牌局；不同种子 → 不同牌局。
-- 反向用例必须有，否则「种子被完全忽略」也能让正向用例通过。
local gA = game.new(4, makeRng(123456), 123456)
local gB = game.new(4, makeRng(123456), 123456)
local gC = game.new(4, makeRng(123457), 123457)

check("同种子两次发牌，dump 完全相同", game.dump(gA) == game.dump(gB))
check("不同种子，dump 不同", game.dump(gA) ~= game.dump(gC))
check("种子落在 g.seed", gA.seed == 123456)

-- 缺 rng 必须当场报错，而不是静默退回 math.random
check("缺 rng 时洗牌报错", pcall(deck.shuffle, { 1, 2, 3 }, nil) == false)

-- ===== 主流程 =====
local d = tonumber(arg and arg[1])
local list
if d == nil then
  list = { 4 }
elseif d == 0 then
  list = { 1, 2, 4 }
else
  list = { d }
end

for _, difficulty in ipairs(list) do
  runOne(difficulty)
end

print("")
print(string.rep("=", 60))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 60))

if failed > 0 then
  os.exit(1)
end
