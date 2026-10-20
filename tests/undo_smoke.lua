-- tests/undo_smoke.lua —— M7 终端验证脚本（撤销 + 计分 + 撤销按钮）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/undo_smoke.lua
--
-- 本脚本不依赖 LÖVE。
--
-- 撤销这块最容易错的三处，下面每一处都有专门的用例：
--   1. 快照只复制了外层 table、没复制牌本身 → 撤销回去的牌和快照是同一个引用；
--   2. 被拒绝的移动/补牌也压了栈 → 玩家按撤销觉得"什么都没撤销"；
--   3. 收组是"顺手"改的（foundations / score / 13 张牌），撤销没把这一起回滚。
-- 所以这里既用【手写确定性牌局】验精确状态，也用【随机真实牌局】验张数守恒。

local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const  = require("const")
local C      = require("src.card")
local layout = require("src.layout")
local game   = require("src.game")

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

-- high 递减到 low 的一串同花正面牌
local function run(suit, high, low, faceUp)
  local out = {}
  for r = high, low, -1 do
    out[#out + 1] = C.new(suit, r, faceUp ~= false)
  end
  return out
end

local function one(suit, rank, faceUp)
  return { C.new(suit, rank, faceUp ~= false) }
end

local function emptyGame()
  local g = game.new(4, function(n) return 1 end)
  for i = 1, const.COLS do g.tableau[i] = {} end
  g.stock = {}
  return g
end

-- 全桌状态签名：把每一张牌（含 faceUp）摊平成字符串。
-- 撤销是否"精确回到上一状态"，直接比较签名即可，不用逐个字段手写断言。
local function cardSig(c)
  return string.format("%s%d%s", c.suit, c.rank, c.faceUp and "+" or "-")
end

local function stateSig(g)
  local parts = {}

  for i = 1, const.COLS do
    local t = {}
    for _, c in ipairs(g.tableau[i]) do t[#t + 1] = cardSig(c) end
    parts[#parts + 1] = "c" .. i .. ":" .. table.concat(t, ",")
  end

  local st = {}
  for _, c in ipairs(g.stock) do st[#st + 1] = cardSig(c) end
  parts[#parts + 1] = "stock:" .. table.concat(st, ",")

  parts[#parts + 1] = string.format("found:S%d H%d D%d C%d",
    g.foundations.spades, g.foundations.hearts,
    g.foundations.diamonds, g.foundations.clubs)

  return table.concat(parts, "|")
end

-- 张数守恒用：tableau + stock + foundation（每 1 组算 13 张）
local function totalCards(g)
  local n = #g.stock
  for i = 1, const.COLS do n = n + #g.tableau[i] end
  return n + game.foundationTotal(g) * 13
end

local function makeRng(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return (s % n) + 1
  end
end

-- ===== 1. 开局：没有历史 =====
section("1. 开局：撤销栈为空")

local g1 = emptyGame()
check("新牌局带空 history 表", type(g1.history) == "table" and #g1.history == 0)
check("undoDepth = 0", game.undoDepth(g1) == 0)
check("canUndo = false", game.canUndo(g1) == false)

local sig1 = stateSig(g1)
local msg1 = game.undo(g1)
check("空栈撤销返回 nothing to undo", contains(msg1, "nothing to undo"))
check("空栈撤销不改牌桌", stateSig(g1) == sig1)
check("空栈撤销不改分数", g1.score == 500)
check("空栈撤销不产生负数步数", g1.moves == 0)

-- ===== 2. 移动 → 撤销 =====
section("2. 一次移动后撤销：精确回到原状态")

local g2 = emptyGame()
g2.tableau[1] = one("spades", 9)
g2.tableau[2] = one("hearts", 10)
local sig2 = stateSig(g2)

game.tryMove(g2, 1, 1, 2)
check("移动后 history = 1", game.undoDepth(g2) == 1)
check("移动后 moves=1 score=499", g2.moves == 1 and g2.score == 499)
check("移动后牌在目标列（第 1 列空、第 2 列 2 张）",
  #g2.tableau[1] == 0 and #g2.tableau[2] == 2)

game.undo(g2)
check("撤销后整桌签名与移动前完全一致", stateSig(g2) == sig2)
check("撤销后 moves 回滚到 0", g2.moves == 0)
check("撤销后 score = 499（回滚到 500 再 -1，撤销不退移动那 1 分）", g2.score == 499)
check("撤销后 history 清空", game.undoDepth(g2) == 0)
check("撤销后没有残留选中态", g2.selected == nil)
check("撤销后 canUndo = false", game.canUndo(g2) == false)

-- ===== 3. 失败的动作不入栈 =====
section("3. 被拒绝的动作不压栈（否则撤销会'什么都没撤销'）")

local g3 = emptyGame()
g3.tableau[1] = one("spades", 9)
g3.tableau[2] = one("hearts", 5)          -- 9 不能落到 5 上
local ok3 = game.tryMove(g3, 1, 1, 2)
check("非法移动返回 false", ok3 == false)
check("非法移动不压栈", game.undoDepth(g3) == 0)
check("非法移动不改牌桌张数", #g3.tableau[1] == 1 and #g3.tableau[2] == 1)

local g3b = emptyGame()
g3b.tableau[1] = one("spades", 9)         -- 其它 9 列空 → 不许补牌
g3b.stock[1] = C.new("clubs", 3, false)
local ok3b = game.dealFromStock(g3b)
check("有空列时补牌被拒", ok3b == false)
check("被拒的补牌不压栈", game.undoDepth(g3b) == 0)
check("被拒的补牌不动 stock", #g3b.stock == 1)

-- 选中 / 取消选中这类"只改界面态"的动作也不该进栈
local g3c = emptyGame()
g3c.tableau[1] = one("spades", 9)
g3c.selected = { col = 1, index = 1 }
game.deselect(g3c)
check("取消选中不压栈", game.undoDepth(g3c) == 0)

-- ===== 4. 撤销要连"自动翻牌"一起回滚 =====
section("4. 撤销翻牌：暴露出来的牌回到背面")

local g4 = emptyGame()
g4.tableau[1] = { C.new("clubs", 9, false), C.new("spades", 5, true) }
g4.tableau[2] = one("hearts", 6)
local sig4 = stateSig(g4)

game.tryMove(g4, 1, 2, 2)
check("移动后第 1 列只剩 9♣ 且被自动翻开", #g4.tableau[1] == 1 and g4.tableau[1][1].faceUp == true)

game.undo(g4)
check("撤销后 9♣ 回到背面", g4.tableau[1][1].faceUp == false)
check("撤销后 5♠ 回到第 1 列", #g4.tableau[1] == 2 and g4.tableau[1][2].rank == 5)
check("撤销后整桌签名一致", stateSig(g4) == sig4)

-- ===== 5. 收组后撤销（M5 + M7 的交叉点）=====
section("5. 成组消除后撤销：foundations / 分数 / 13 张牌一起回滚")

local g5 = emptyGame()
g5.tableau[1] = run("spades", 13, 2)      -- ♠K..2（12 张，顶牌 2）
g5.tableau[2] = one("spades", 1)          -- ♠A
local sig5   = stateSig(g5)
local total5 = totalCards(g5)

game.tryMove(g5, 2, 1, 1)
check("移动补齐 → 收走一组", g5.foundations.spades == 1)
check("收组后 moves=1 score=599", g5.moves == 1 and g5.score == 599)
check("收组后全桌张数守恒（13 张计入 foundation）", totalCards(g5) == total5)

game.undo(g5)
check("撤销后 foundations 归零", g5.foundations.spades == 0 and game.foundationTotal(g5) == 0)
check("撤销后 13 张牌回到列里（第 1 列 12 张、第 2 列 1 张）",
  #g5.tableau[1] == 12 and #g5.tableau[2] == 1)
check("撤销后整桌签名与收组前一致", stateSig(g5) == sig5)
check("撤销后全桌张数仍守恒", totalCards(g5) == total5)
check("撤销后 score = 499（+100 随快照一起消失，撤销再 -1）", g5.score == 499)
check("撤销后 moves 回滚到 0", g5.moves == 0)

-- ===== 6. 补牌 → 撤销 =====
section("6. 补牌后撤销：stock 一张不差地回去")

local g6 = game.new(4, makeRng(7))
local sig6 = stateSig(g6)

game.dealFromStock(g6)
check("补牌后 stock 50 -> 40", #g6.stock == 40)
check("补牌后 history = 1", game.undoDepth(g6) == 1)

game.undo(g6)
check("撤销后 stock 回 50 张", #g6.stock == 50)
check("撤销后整桌签名一致（含取牌顺序 LIFO）", stateSig(g6) == sig6)
check("撤销后 moves=0 score=499", g6.moves == 0 and g6.score == 499)

-- ===== 7. 连续多次撤销回到开局 =====
section("7. 连补 5 轮后连撤 5 次：回到开局")

local g7 = game.new(2, makeRng(11))
local sig7 = stateSig(g7)

for _ = 1, 5 do game.dealFromStock(g7) end
check("连补 5 轮后 history = 5", game.undoDepth(g7) == 5)
check("连补 5 轮后 stock 空", #g7.stock == 0)
check("连补 5 轮后 moves=5 score=495", g7.moves == 5 and g7.score == 495)

for _ = 1, 5 do game.undo(g7) end
check("5 次撤销后回到开局状态", stateSig(g7) == sig7)
check("5 次撤销后 history 空", game.undoDepth(g7) == 0)
check("5 次撤销后 moves=0", g7.moves == 0)
check("5 次撤销后 score = 499（每次撤销扣 1，共 5 次）", g7.score == 499)
check("第 6 次撤销被拒绝", contains(game.undo(g7), "nothing to undo"))

-- ===== 8. 栈上限 =====
section("8. 撤销栈上限 100")

local g8 = game.new(4, makeRng(13))
for _ = 1, 120 do game.pushHistory(g8) end
check("压 120 次后栈长度仍是 100", game.undoDepth(g8) == 100)

local undone = 0
while game.canUndo(g8) do
  game.undo(g8)
  undone = undone + 1
  if undone > 200 then break end               -- 死循环保护：真出问题别把终端卡住
end
check("能把 100 步全部撤完（且没卡住）", undone == 100)

-- ===== 9. 深拷贝隔离：快照之间不能共享牌对象 =====
section("9. 深拷贝：几份快照之间互不污染")

local g9 = emptyGame()
g9.tableau[1] = one("spades", 9)
g9.tableau[2] = one("hearts", 10)

local refBefore = g9.tableau[1][1]
game.tryMove(g9, 1, 1, 2)
local moved = g9.tableau[2][2]
check("移动只搬引用（同一张牌当然还是同一个 table）", moved == refBefore)

game.undo(g9)
local back = g9.tableau[1][1]
check("撤销拿回的是快照里的副本，不是移动时那张 table", back ~= moved)
check("副本内容一致（9♠ 正面）",
  back.suit == "spades" and back.rank == 9 and back.faceUp == true)

-- 更硬的一条：两份快照里同一张牌的状态不同，撤销两遍不会串味。
-- 如果快照只贴了外层 table（牌还是同一个引用），第二次撤销会读到被改过的状态。
local g9b = emptyGame()
g9b.tableau[1] = one("spades", 9)

game.pushHistory(g9b)                     -- 快照 A：9♠ 正面
g9b.tableau[1][1].faceUp = false          -- 手动改，但不再压快照
game.pushHistory(g9b)                     -- 快照 B：9♠ 背面

game.undo(g9b)
check("撤销 1 步回到快照 B（背面）", g9b.tableau[1][1].faceUp == false)
game.undo(g9b)
check("撤销 2 步回到快照 A（正面）—— 两份快照没有共享同一个牌对象",
  g9b.tableau[1][1].faceUp == true)

-- ===== 10. 撤销按钮：命中检测 + 点击链路 =====
section("10. 撤销按钮：几何不打架 + 点得中")

local ux = const.UNDO_X + const.UNDO_W / 2
local uy = const.UNDO_Y + const.UNDO_H / 2

check("按钮中心命中 hitTestUndo", layout.hitTestUndo(ux, uy) == true)
check("按钮左侧外不命中", layout.hitTestUndo(const.UNDO_X - 4, uy) == false)
check("按钮右侧外不命中", layout.hitTestUndo(const.UNDO_X + const.UNDO_W + 4, uy) == false)
check("按钮上方外不命中", layout.hitTestUndo(ux, const.UNDO_Y - 4) == false)

-- 布局守卫：按钮不能压到 foundation 槽 / stock / 列落点带
check("按钮在第 8 个 foundation 槽右边",
  const.UNDO_X >= const.foundSlotX(8) + const.FOUND_W)
check("按钮不压到 stock", const.UNDO_X + const.UNDO_W <= const.STOCK_X)
check("按钮不在任何列的落点带里（否则点它会被当成落点）",
  layout.columnBandAt(ux, uy) == nil)
check("按钮在 HUD 之下、牌桌提示行之上",
  const.UNDO_Y > const.HUD_H and const.UNDO_Y + const.UNDO_H < const.MSG_Y)

local g10 = emptyGame()
g10.tableau[1] = one("spades", 9)
g10.tableau[2] = one("hearts", 10)
game.tryMove(g10, 1, 1, 2)

local msg10 = game.clickAt(g10, ux, uy)
check("点按钮 → 撤销生效（history 清空、牌回原位）",
  game.undoDepth(g10) == 0 and #g10.tableau[1] == 1 and #g10.tableau[2] == 1)
check("提示里带 undo", contains(msg10, "undo"))

local msg10b = game.clickAt(g10, ux, uy)    -- 再点一次（已经没得撤）
check("按钮在空栈时给出 nothing to undo", contains(msg10b, "nothing to undo"))

-- ===== 11. 撤销只动牌局，不动设置/选中 =====
section("11. 撤销的影响范围")

local g11 = emptyGame()
g11.tableau[1] = one("spades", 9)
g11.tableau[2] = one("hearts", 10)
g11.tableau[3] = one("clubs", 4)

game.tryMove(g11, 1, 1, 2)
g11.selected = { col = 2, index = 2 }      -- 假装玩家已经选中了别的东西
game.undo(g11)

check("撤销会清掉选中态", g11.selected == nil)
check("撤销不动 difficulty", g11.difficulty == 4)
check("撤销后 history 仍是一张表（能继续压栈）", type(g11.history) == "table")
check("撤销不动其它列", #g11.tableau[3] == 1 and g11.tableau[3][1].rank == 4)

-- ===== 12. 真实牌局：撤销之后还能继续正常操作 =====
section("12. 真实随机牌局：撤销 → 再操作，状态不串")

local g12 = game.new(4, makeRng(99))
check("开局 104 张", totalCards(g12) == 104)

for _ = 1, 3 do game.dealFromStock(g12) end
check("连补 3 轮后 stock = 20", #g12.stock == 20)

game.undo(g12)
game.undo(g12)
check("撤销 2 次后 stock = 40", #g12.stock == 40)
check("撤销 2 次后 history = 1", game.undoDepth(g12) == 1)

local ok12 = game.dealFromStock(g12)
check("撤销之后还能继续补牌", ok12 == true and #g12.stock == 30)
check("全桌张数仍守恒（104）", totalCards(g12) == 104)
check("dump 里带 undo 计数", contains(game.dump(g12), "undo="))

-- ===== 13. 随机压力测试：随机点击 + 随机撤销 =====
section("13. 3000 步随机操作：牌不会丢、不会复制、栈不越界")

local g13 = game.new(1, makeRng(2026))       -- 1 花色：合法移动多，能压到更多分支
local drv = makeRng(777)

local lostOrDuped = 0
local stackOverflow = 0
local brokenCols = 0

for _ = 1, 3000 do
  local roll = drv(100)

  if roll <= 12 then
    game.undo(g13)                            -- 12% 撤销
  elseif roll <= 22 then
    game.clickAt(g13, const.STOCK_X + 10, const.STOCK_Y + 10)     -- 10% 点牌库
  else
    -- 剩下 78%：点某列的一张牌，或者点那一列的落点带（空白处）
    local c   = drv(const.COLS)
    local col = g13.tableau[c]

    if #col > 0 and drv(2) == 1 then
      local k = drv(#col)
      game.clickAt(g13, const.colX(c) + 20, layout.cardY(col, k) + 4)
    else
      game.clickAt(g13, const.colX(c) + 20, 480)                  -- 落点带里
    end
  end

  -- 每一步都查不变量
  if totalCards(g13) ~= 104 then lostOrDuped = lostOrDuped + 1 end
  if game.undoDepth(g13) > 100 then stackOverflow = stackOverflow + 1 end
  if #g13.tableau ~= const.COLS then brokenCols = brokenCols + 1 end

  -- 万一 1 花色真被凑赢了，撤一步继续折腾（顺便验证"赢了也能撤回没赢"）
  if game.isWon(g13) then game.undo(g13) end
end

check("3000 步之后全桌仍是 104 张（没丢牌、没复制）", lostOrDuped == 0 and totalCards(g13) == 104)
check("撤销栈始终没超过 100", stackOverflow == 0)
check("10 列结构始终完整", brokenCols == 0)
check("moves 不是负数", g13.moves >= 0)
check("撤销到底之后还能继续操作", (function()
  while game.canUndo(g13) do game.undo(g13) end
  local before = totalCards(g13)
  game.clickAt(g13, const.colX(1) + 20, const.TABLEAU_Y + 20)
  return totalCards(g13) == before
end)())

-- 汇总
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
