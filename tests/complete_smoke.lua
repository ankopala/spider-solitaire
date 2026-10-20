-- tests/complete_smoke.lua —— M5 终端验证脚本（成组消除 + 胜利）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/complete_smoke.lua
--
-- 本脚本不依赖 LÖVE。
--
-- 与 stock_smoke 的区别：那边用随机牌局验"不变量"；这边必须用【手写的确定性牌局】，
-- 因为随机发牌几乎不可能凑出 K→A 完整序列 —— 靠随机会一辈子测不到成组逻辑。
-- 所以下面每个用例都是先把 tableau 清空、再手工摆牌。

-- 修正 package.path：让 require("src.xxx") 与 LÖVE 里写法一致
local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const = require("const")
local C     = require("src.card")
local rules = require("src.rules")
local game  = require("src.game")

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

local function contains(s, needle)
  return string.find(s or "", needle, 1, true) ~= nil
end

-- ===== 造牌工具 =====

-- 一列：run(suit, high, low) 生成 high 递减到 low 的序列，全正面
local function run(suit, high, low, faceUp)
  local out = {}
  for r = high, low, -1 do
    out[#out + 1] = C.new(suit, r, faceUp ~= false)
  end
  return out
end

-- 把若干段拼成一列（按参数顺序，前面的在下面）
local function concat(...)
  local out = {}
  local parts = { ... }
  for _, p in ipairs(parts) do
    for _, c in ipairs(p) do out[#out + 1] = c end
  end
  return out
end

local function one(suit, rank, faceUp)
  return { C.new(suit, rank, faceUp ~= false) }
end

-- 空牌桌：10 列全空、stock 空（只留待测的那几列，避免干扰计数）
local function emptyGame()
  local g = game.new(4, function(n) return 1 end)
  for i = 1, const.COLS do g.tableau[i] = {} end
  g.stock = {}
  return g
end

-- 总张数（tableau + stock + foundation 组数 × 13）
local function totalCards(g)
  local n = #g.stock
  for i = 1, const.COLS do n = n + #g.tableau[i] end
  n = n + game.foundationTotal(g) * 13
  return n
end

local function colSizes(g)
  local t = {}
  for i = 1, const.COLS do t[i] = #g.tableau[i] end
  return t
end

-- ===== 1. 规则层：completeSetSuit =====
section("1. rules.completeSetSuit：列尾 13 张是否同花 K→A")

check("♠ K→A 13 张 → 返回 spades", rules.completeSetSuit(run("spades", 13, 1)) == "spades")
check("♥ K→A 13 张 → 返回 hearts", rules.completeSetSuit(run("hearts", 13, 1)) == "hearts")
check("♦ K→A 13 张 → 返回 diamonds", rules.completeSetSuit(run("diamonds", 13, 1)) == "diamonds")
check("♣ K→A 13 张 → 返回 clubs", rules.completeSetSuit(run("clubs", 13, 1)) == "clubs")

check("只有 12 张（K..2，缺 A）→ nil",
  rules.completeSetSuit(run("spades", 13, 2)) == nil)

check("13 张但顺序是 A→K（升序）→ nil",
  rules.completeSetSuit(run("spades", 1, 13)) == nil)

-- 换掉中间一张的花色：K Q J 10 9 8 [♥7] 6 5 4 3 2 A
local mixed = run("spades", 13, 8)
mixed[#mixed + 1] = C.new("hearts", 7, true)
for _, c in ipairs(run("spades", 6, 1)) do mixed[#mixed + 1] = c end
check("13 张同降序但混了一张 ♥7 → nil", rules.completeSetSuit(mixed) == nil)

-- 点数不连续：K Q 10 J 9 8 7 6 5 4 3 2 A（10 和 J 调换）
local gapped = { C.new("spades", 13, true), C.new("spades", 12, true),
                 C.new("spades", 10, true), C.new("spades", 11, true) }
for _, c in ipairs(run("spades", 9, 1)) do gapped[#gapped + 1] = c end
check("13 张同花但点数有缺口 → nil", rules.completeSetSuit(gapped) == nil)

-- 其中一张背面（把 5 翻过去）
local hidden = run("spades", 13, 1)
hidden[9].faceUp = false
check("同花 K→A 但第 9 张是背面 → nil", rules.completeSetSuit(hidden) == nil)

-- 列底多一张不相关的牌，列尾仍是完整 K→A → 仍成立
local withExtra = concat(one("clubs", 9), run("spades", 13, 1))
check("列尾 13 张完整、上方压着别的牌 → 仍返回 spades",
  rules.completeSetSuit(withExtra) == "spades")

-- 反过来：完整 K→A 之后又压了一张背面牌 → 不算（组不在列尾）
local covered = concat(run("spades", 13, 1), one("clubs", 9, false))
check("K→A 已凑齐但列尾又压了背面牌 → nil", rules.completeSetSuit(covered) == nil)

-- ===== 2. 收集一组：牌、分数、张数 =====
section("2. game.collectCompleteSets：收走一组")

local g2 = emptyGame()
g2.tableau[1] = run("spades", 13, 1)
g2.tableau[2] = run("hearts", 9, 5)          -- 别列，不该被动
local before2 = totalCards(g2)

local res2 = game.collectCompleteSets(g2)
check("返回 count = 1", res2.count == 1)
check("返回的花色是 spades", res2.suits[1] == "spades")
check("第 1 列被清空", #g2.tableau[1] == 0)
check("foundations.spades = 1", g2.foundations.spades == 1)
check("foundationTotal = 1", game.foundationTotal(g2) == 1)
check("score 500 -> 600（+100）", g2.score == 600)
check("别列没被动（5 张仍在）", #g2.tableau[2] == 5)
check("全桌张数守恒（13 张进了 foundation）", totalCards(g2) == before2)

-- ===== 3. 收走之后自动翻开新顶牌 =====
section("3. 收走后暴露出来的背面牌要自动翻开")

local g3 = emptyGame()
-- 第 1 列：一张背面 9♣，上面压着完整的 ♠K→A
g3.tableau[1] = concat(one("clubs", 9, false), run("spades", 13, 1))
check("摆好后列尾是完整序列", rules.completeSetSuit(g3.tableau[1]) == "spades")

game.collectCompleteSets(g3)
check("只剩 1 张", #g3.tableau[1] == 1)
check("剩下那张是 9♣", g3.tableau[1][1].rank == 9 and g3.tableau[1][1].suit == "clubs")
check("它被自动翻成正面", g3.tableau[1][1].faceUp == true)

-- ===== 4. 同一列连锁收两组 =====
section("4. 同一列里叠着两组：一次调用全部收走")

local g4 = emptyGame()
g4.tableau[1] = concat(run("spades", 13, 1), run("spades", 13, 1))
local res4 = game.collectCompleteSets(g4)
check("count = 2", res4.count == 2)
check("第 1 列清空", #g4.tableau[1] == 0)
check("foundations.spades = 2", g4.foundations.spades == 2)
check("score 500 -> 700（+200）", g4.score == 700)

-- ===== 5. 不成组时不动 =====
section("5. 不成组的列：什么都不改")

local g5 = emptyGame()
g5.tableau[1] = run("spades", 13, 2)          -- 差一张 A
g5.tableau[2] = mixed                         -- 混花色
local before5 = colSizes(g5)

local res5 = game.collectCompleteSets(g5)
check("count = 0", res5.count == 0)
check("各列张数不变", #g5.tableau[1] == 12 and #g5.tableau[2] == 13)
check("foundations 全 0", game.foundationTotal(g5) == 0)
check("score 不变（仍是 500）", g5.score == 500)

-- ===== 6. 移动补齐 → 自动收组 =====
section("6. 链路：tryMove 把 A 放上去 → 收走整组")

local g6 = emptyGame()
g6.tableau[1] = run("spades", 13, 2)          -- ♠K..2（12 张，顶牌 2）
g6.tableau[2] = one("spades", 1)              -- ♠A

local ok6, msg6 = game.tryMove(g6, 2, 1, 1)
check("移动成功", ok6 == true)
check("第 1 列被收空", #g6.tableau[1] == 0)
check("第 2 列空（A 被搬走了）", #g6.tableau[2] == 0)
check("foundations.spades = 1", g6.foundations.spades == 1)
check("moves = 1", g6.moves == 1)
check("score = 599（-1 移动 +100 收组）", g6.score == 599)
check("提示含 completed 1 set", contains(msg6, "completed 1 set"))
check("提示含 +100", contains(msg6, "+100"))
check("提示末尾分数是 599", contains(msg6, "score 599"))
check("选中态已清空", g6.selected == nil)

-- ===== 7. 补牌补齐 → 自动收组 =====
section("7. 链路：dealFromStock 补上 A → 收走整组")

local g7 = emptyGame()
g7.tableau[1] = run("spades", 13, 2)          -- 顶牌 2♠，等一张 A
for i = 2, const.COLS do
  g7.tableau[i] = one("hearts", 9)            -- 其它 9 列各一张，满足"补牌需全列非空"
end

-- 补牌从 stock 尾部取：第 1 列拿到 stock 的最后一张 → 把 A♠ 放最后
for i = 1, 9 do g7.stock[i] = C.new("clubs", 3, false) end
g7.stock[10] = C.new("spades", 1, false)

local ok7, msg7 = game.dealFromStock(g7)
check("补牌成功", ok7 == true)
check("stock 10 -> 0", #g7.stock == 0)
check("第 1 列被收空", #g7.tableau[1] == 0)
check("其它列各 +1 张", #g7.tableau[2] == 2 and #g7.tableau[10] == 2)
check("foundations.spades = 1", g7.foundations.spades == 1)
check("score = 599（-1 补牌 +100 收组）", g7.score == 599)
check("提示含 completed 1 set", contains(msg7, "completed 1 set"))
check("补来的牌一律正面朝上", g7.tableau[2][2].faceUp == true)

-- ===== 8. 收组后出现空列 → 禁止补牌 =====
section("8. 收组把列收空 → 该列变成空列，禁止补牌")

local g8 = emptyGame()
g8.tableau[1] = run("spades", 13, 1)
for i = 2, const.COLS do g8.tableau[i] = one("hearts", 9) end
for i = 1, 10 do g8.stock[i] = C.new("clubs", 4, false) end

game.collectCompleteSets(g8)
check("第 1 列被收空", #g8.tableau[1] == 0)
check("firstEmptyColumn 找到第 1 列", game.firstEmptyColumn(g8) == 1)

local ok8, msg8 = game.dealFromStock(g8)
check("补牌被拒绝", ok8 == false)
check("提示指出第 1 列为空", contains(msg8, "col 1 is empty"))
check("stock 没被动（仍 10 张）", #g8.stock == 10)

-- ===== 9. 胜利判定 =====
section("9. 胜利判定：8 组")

local g9 = emptyGame()
check("0 组 → 没赢", game.isWon(g9) == false)
g9.foundations = { spades = 2, hearts = 1, diamonds = 2, clubs = 2 }
check("7 组 → 没赢", game.foundationTotal(g9) == 7 and game.isWon(g9) == false)

-- 收下第 8 组（♥K→A）
g9.tableau[3] = run("hearts", 13, 1)
local res9 = game.collectCompleteSets(g9)
check("收了 1 组", res9.count == 1)
check("foundations.hearts 1 -> 2", g9.foundations.hearts == 2)
check("总数 8 → isWon = true", game.foundationTotal(g9) == 8 and game.isWon(g9) == true)

-- 赢了之后再点牌桌：不再改变任何状态
local g9b = emptyGame()
g9b.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }
g9b.tableau[1] = run("spades", 13, 2)
g9b.tableau[2] = one("spades", 1)
local sizesBefore = colSizes(g9b)
local msg9 = game.clickAt(g9b, const.colX(1) + 10, const.TABLEAU_Y + 10)
check("赢后点击返回 you won 提示", contains(msg9, "you won"))
check("赢后点击不改牌桌", #g9b.tableau[1] == 12 and #g9b.tableau[2] == 1)
check("赢后点击不记步数", g9b.moves == 0)
check("赢后点击不清 score", g9b.score == 500)
check("赢后 isWon 仍为 true", game.isWon(g9b) == true)

-- ===== 10. 真实牌局上跑一遍：张数守恒、不误收 =====
section("10. 真实随机牌局：正常移动/补牌不会凭空收组")

local function makeRng(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return (s % n) + 1
  end
end

local g10 = game.new(4, makeRng(20261019))
local before10 = totalCards(g10)
check("开局 104 张", before10 == 104)
check("开局 0 组、未胜利", game.foundationTotal(g10) == 0 and game.isWon(g10) == false)

for _ = 1, 5 do game.dealFromStock(g10) end
check("连补 5 轮后仍是 104 张", totalCards(g10) == 104)
check("随机牌局不会误收组（foundations 仍 0）", game.foundationTotal(g10) == 0)

local okDump = pcall(function() return game.dump(g10) end)
check("dump 正常返回（含 x/8 计数）", okDump == true)

-- 汇总
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
