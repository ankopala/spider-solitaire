-- tests/hint_smoke.lua —— M9「还有没有牌可动」的判定（终端验证，不需要 LÖVE）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/hint_smoke.lua
--
-- 为什么全用【手写牌局】：随机发牌几乎撞不上「只剩一个空列」「整列搬到空列不算走法」
-- 这类边界，而这几条正是这个判定最容易写错、也最容易悄悄失效的地方。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const  = require("const")
local game   = require("src.game")
local hint   = require("src.hint")
local layout = require("src.layout")
local rules  = require("src.rules")

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

-- ===== 手写牌局工具 =====

local function card(suit, rank)
  return { suit = suit, rank = rank, faceUp = true }
end

local function emptyGame()
  local g = {
    tableau     = {},
    stock       = {},
    foundations = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 },
    score       = 500,
    moves       = 0,
    selected    = nil,
    message     = "",
    history     = {},
    events      = {},
    difficulty  = 4,
  }
  for i = 1, const.COLS do g.tableau[i] = {} end
  return g
end

local function put(g, col, cards)
  for _, c in ipairs(cards) do
    g.tableau[col][#g.tableau[col] + 1] = c
  end
  return g
end

local function stockUp(g, n)
  for k = 1, n do
    g.stock[#g.stock + 1] = { suit = "spades", rank = (k % 13) + 1, faceUp = false }
  end
  return g
end

-- 一副「绝对无路可走」的牌局：10 列各 1 张，点数全是偶数。
-- 偶数 + 1 一定是奇数，而场上没有奇数 → 谁也放不到谁头上；
-- 每列只有 1 张（index == 1），所以「整列搬到空列」那条捷径也不成立。
local NO_MOVE = { 2, 4, 6, 8, 10, 12, 2, 4, 6, 8 }

local function noMoveBoard()
  local g = emptyGame()
  for i = 1, const.COLS do put(g, i, { card("spades", NO_MOVE[i]) }) end
  return g
end

-- 做「有路」牌局时用的填充列：点数都在 2..10 且全偶数，
-- 既不会自己接上，也不会给 11/12 提供落点。
local FILL = { 2, 4, 6, 8, 10, 2, 4, 6 }

local function fillRest(g, fromCol)
  for k = 1, #FILL do
    put(g, fromCol + k - 1, { card("spades", FILL[k]) })
  end
  return g
end

local function makeRng(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return (s % n) + 1
  end
end

-- ===== 1. 单张：不限花色 =====
section("1. 单张落点不限花色")

local g1 = emptyGame()
put(g1, 1, { card("spades", 9) })
put(g1, 2, { card("hearts", 10) })

local m1 = hint.findMove(g1)
check("红 10 能接黑 9", m1 ~= nil)
check("指向 col 2、搬 1 张", m1 and m1.from == 1 and m1.index == 1 and m1.to == 2 and m1.count == 1)
check("这一手用 game.tryMove 真的走得成",
  m1 ~= nil and game.tryMove(g1, m1.from, m1.index, m1.to) == true)

-- ===== 2. 整段：同花降序能整组搬，断一张就搬不动 =====
section("2. 整段移动：同花降序才成立")

local function runBoard(secondRank)
  local g = emptyGame()
  put(g, 1, { card("spades", 12), card("spades", secondRank) })
  put(g, 2, { card("clubs", 13) })
  -- 填充列刻意【不含 10】：否则 10♠ 会落到 col1 的 J♠ 上（同花接续 +60），
  -- 那一手确实更值得走，但会把"QJ 整段搬迁"挤掉，本条断言就测不到了。
  local FILL_NO10 = { 2, 4, 6, 8, 2, 4, 6, 8 }
  for k = 1, #FILL_NO10 do
    put(g, 3 + k - 1, { card("spades", FILL_NO10[k]) })
  end
  return g
end

local g2 = runBoard(11)              -- Q♠ J♠ → 可以整段放到 K♣ 上
local m2 = hint.findMove(g2)
check("Q-J 同花降序，能整段搬到 K 上", m2 ~= nil)
check("搬的是 2 张，从 Q 起", m2 and m2.from == 1 and m2.index == 1 and m2.count == 2 and m2.to == 2)
check("这一手真的走得成", m2 ~= nil and game.tryMove(g2, m2.from, m2.index, m2.to) == true)

local g2b = runBoard(8)              -- Q♠ 8♠ → 不是连续序列
check("中间断开的序列整段搬不动，且没有别的走法", hint.findMove(g2b) == nil)

-- ===== 3. 混花色：整段不行，但尾巴那一张单走可以 =====
section("3. 混花色序列只有尾巴能动")

local g3 = emptyGame()
put(g3, 1, { card("spades", 10), card("hearts", 9) })
put(g3, 2, { card("clubs", 13) })
-- 填充列：col7 是 10（9♥ 的落点）。刻意不放 8（8 会落到 9♥ 上抢走提示），
-- 也不放 J（J 会被 10♠ 落上去）—— 所以不能复用上面的 fillRest。
local FILL_G3 = { 2, 4, 6, 2, 10, 4, 6, 2 }
for k = 1, #FILL_G3 do
  put(g3, 3 + k - 1, { card("spades", FILL_G3[k]) })
end
local m3 = hint.findMove(g3)
check("混花色 10-9 不能整段搬", rules.canPickUp(g3.tableau[1], 1) == false)
check("但 9♥ 单张能搬到 col 7 的 10 上",
  m3 ~= nil and m3.from == 1 and m3.index == 2 and m3.count == 1 and m3.to == 7)

-- ===== 4/5. 三档状态 =====
section("4. 三档：moves / deal / stuck")

local g4 = noMoveBoard()
local s4 = hint.status(g4)
check("10 列全是偶数单张 → 找不到任何走法", hint.findMove(g4) == nil)
check("stock 也空 → stuck", s4 == "stuck")

local g5 = noMoveBoard()
stockUp(g5, 10)
check("10 列全非空 + stock 有牌 → deal（补牌本身就是合法动作）", hint.status(g5) == "deal")

local g5b = noMoveBoard()
stockUp(g5b, 10)
g5b.tableau[10] = {}                 -- 留一个空列
local s5b = hint.status(g5b)
check("有空列时不许补牌 → 仍是 stuck", s5b == "stuck")

-- ===== 6. 空列那条规则 =====
section("6. 空列：整列搬家不算走法，i > 1 才算")

local g6 = emptyGame()
for i = 1, 9 do put(g6, i, { card("spades", NO_MOVE[i]) }) end
check("每列只剩 1 张 + 一个空列 → 整列搬家不算，仍然无路",
  hint.findMove(g6) == nil and hint.status(g6) == "stuck")

-- 同一副牌，把第 1 列变成 2 张（上面那张可以单独搬走）→ 就有路了
local g6b = emptyGame()
put(g6b, 1, { card("spades", 5), card("diamonds", 2) })
for k = 1, 8 do put(g6b, k + 1, { card("spades", ({ 4, 6, 8, 10, 12, 4, 6, 8 })[k]) }) end
local m6b = hint.findMove(g6b)
check("搬走上面那张会露出下面的牌 → 算有路", m6b ~= nil)
check("落点是那个空列", m6b and m6b.index == 2 and m6b.to == 10)

-- ===== 7. 提示的手必须真的能走（同源检查）=====
section("7. 提示与规则同源")

check("第 1 种牌局：能走", (function()
  local g = emptyGame()
  put(g, 1, { card("spades", 9) })
  put(g, 2, { card("hearts", 10) })
  local m = hint.findMove(g)
  return m ~= nil and game.tryMove(g, m.from, m.index, m.to) == true
end)())

check("第 3 种牌局（混花色）：能走", (function()
  local g = emptyGame()
  put(g, 1, { card("spades", 10), card("hearts", 9) })
  put(g, 2, { card("clubs", 13) })
  fillRest(g, 3)
  local m = hint.findMove(g)
  return m ~= nil and game.tryMove(g, m.from, m.index, m.to) == true
end)())

-- ===== 8. 穷举等价性 =====
section("8. 穷举等价性：每步都和 rules 双重循环比对")

-- oracle 用最笨的写法重算一遍（不共享 hint 的任何代码，只共享 rules）
local function oracle(g)
  for c = 1, const.COLS do
    local src = g.tableau[c]
    for i = 1, #src do
      if rules.canPickUp(src, i) then
        for d = 1, const.COLS do
          if d ~= c then
            local dst = g.tableau[d]
            if #dst == 0 then
              if i > 1 then return true end
            elseif rules.canDrop(dst, src[i].rank) then
              return true
            end
          end
        end
      end
    end
  end
  return false
end

local g8 = game.new(4, makeRng(20261019))
local mism, badMove, steps = 0, 0, 0

for _ = 1, 200 do
  local hasOracle = oracle(g8)
  local m = hint.findMove(g8)

  if hasOracle ~= (m ~= nil) then mism = mism + 1 end

  if m then
    if not game.tryMove(g8, m.from, m.index, m.to) then badMove = badMove + 1 end
  else
    -- 没牌可动就补牌；补不了说明这局到头了
    if not game.dealFromStock(g8) then break end
  end
  steps = steps + 1
end

check("200 步比对零分歧", mism == 0)
check("提示的每一手都真的走成了", badMove == 0)
check("循环确实跑了一段（没有一开始就退出）", steps >= 10)

-- ===== 9. 只读 =====
section("9. findMove / status 不修改牌局")

local g9 = game.new(2, makeRng(777))
local before = game.dump(g9)
hint.findMove(g9)
hint.status(g9)
check("dump 一字不变", game.dump(g9) == before)

-- ===== 10. 择优：不是"第一个能走的"，而是"最值得走的" =====
section("10. 择优：能翻牌的候选永远排在前面")

-- 扫描顺序上 col1 先出现（5♠ → 6♠ 同花接续，60 分），
-- 但 col9 那一手会翻开一张背面牌（+100），必须赢。
-- ⚠ 其余列必须填满：空列会提供"搬到空列"这种 +10 的候选，把断言搅浑。
local g10 = emptyGame()
put(g10, 1,  { card("spades", 5) })
put(g10, 2,  { card("spades", 6) })
for k = 1, 6 do
  put(g10, 2 + k, { card("spades", ({ 2, 4, 6, 8, 2, 4 })[k]) })
end
put(g10, 9,  { { suit = "clubs", rank = 9, faceUp = false }, card("hearts", 8) })
put(g10, 10, { card("clubs", 9) })
local m10 = hint.findMove(g10)
check("选了后面那手能翻牌的，而不是先扫到的同花接续",
  m10 ~= nil and m10.from == 9 and m10.index == 2 and m10.to == 10)
check("move 上带 flips = true", m10 ~= nil and m10.flips == true)
check("同花接续那手确实也存在（否则这条测试没意义）",
  rules.canDrop(g10.tableau[2], 5) == true)

-- ===== 11. 不重复上一步的逆向操作 =====
section("11. 逆操作：不禁止，但排到最后")

-- 上一步是 col2 → col1（5♠ 搬到 6♠ 上），现在 col2 空了。
-- 把 6♠5♠ / 5♠ 搬回 col2 属于"原路返回"，只要还有别的选择就不该选它。
-- 真实的 2 步往返长什么样：col1 = [10♥, 9♠]，col2 = [10♠]。
-- 9♠ 落到 10♠ 上（异花）→ 上一手记成 1→2。现在 col1 顶是 10♥、col2 顶是 9♠，
-- 于是"9♠ 落回 10♥"又是一步合法移动 —— 这就是玩家看到的 A→B 再 B→A。
local function pingpongBoard(withEscape)
  local g = emptyGame()
  put(g, 1, { card("hearts", 10) })
  put(g, 2, { card("spades", 10), card("spades", 9) })
  -- 其余列填满且刻意不放 8 / J：这两张会各自多造出一个候选，把断言搅浑
  local FILL_PP = { 2, 4, 6, 2, 4, 6, 2, 4 }
  for k = 1, #FILL_PP do
    put(g, 2 + k, { card("spades", FILL_PP[k]) })
  end
  if withEscape then
    -- 另一条出路：col4 上面那张 7♦ 搬走会翻开背面 8♣（+100）
    g.tableau[3] = { card("spades", 8) }
    g.tableau[4] = { { suit = "clubs", rank = 8, faceUp = false }, card("diamonds", 7) }
  end
  g.lastMove = { from = 1, to = 2 }
  return g
end

local m11 = hint.findMove(pingpongBoard(true))
check("有别的走法时避开原路返回", m11 ~= nil and m11.from == 4 and m11.to == 3)
check("没走回 col2", m11 ~= nil and m11.to ~= 2)

local m11b = hint.findMove(pingpongBoard(false))
check("只剩原路返回时仍然给答案（宁可给笨答案，也不谎报无路）",
  m11b ~= nil and m11b.from == 2 and m11b.to == 1)

-- 补牌之后"上一步"就该失效：牌桌 10 列全变了，谈"搬回去"没有意义
local g11c = game.new(4, makeRng(4242))
g11c.lastMove = { from = 1, to = 2 }
game.dealFromStock(g11c)
check("补牌会清掉 lastMove", g11c.lastMove == nil)

-- ===== 12. stall：有牌可动，但一手翻牌的都没有 =====
section("12. stall：只剩无意义的挪动")

local function stallBoard()
  local g = emptyGame()
  put(g, 1, { card("spades", 5) })
  put(g, 2, { card("spades", 6) })
  for k = 1, 8 do
    put(g, 3 + k - 1, { card("spades", ({ 2, 4, 6, 8, 10, 2, 4, 6 })[k]) })
  end
  return g
end

local g12 = stallBoard()
check("确实有牌可动（不是 stuck）", hint.findMove(g12) ~= nil)
check("但一手都翻不了牌 + stock 空 → stall", hint.status(g12) == "stall")

local g12b = stallBoard()
stockUp(g12b, 10)
check("还能补牌时不算 stall（补牌本身会翻开 10 张新牌）",
  hint.status(g12b) == "moves")

local g12c = emptyGame()
put(g12c, 9, { { suit = "clubs", rank = 9, faceUp = false }, card("hearts", 8) })
put(g12c, 10, { card("clubs", 9) })
check("有能翻牌的走法 → moves（哪怕 stock 是空的）",
  hint.status(g12c) == "moves")

-- ===== 13. 按钮几何 =====
section("10. 提示按钮的几何")

local hx = const.HINT_X + const.HINT_W / 2
local hy = const.HINT_Y + const.HINT_H / 2

check("中心命中", layout.hitTestHint(hx, hy) == true)
check("左边界外不命中", layout.hitTestHint(const.HINT_X - 1, hy) == false)
check("右边界外不命中", layout.hitTestHint(const.HINT_X + const.HINT_W + 1, hy) == false)
check("与 Undo 按钮不重叠", layout.hitTestUndo(hx, hy) == false)
check("与 Undo 之间留了间隙", const.HINT_X >= const.UNDO_X + const.UNDO_W)
check("右边不压到 stock", const.HINT_X + const.HINT_W <= const.STOCK_X)
check("整个按钮在落点带之下（点它不会被当成落到某列）",
  const.HINT_Y > const.BAND_BOTTOM and layout.columnBandAt(hx, hy) == nil)

-- ===== 14. findMoves：全部候选（M14「连按 H 循环」的数据源）=====
section("14. findMoves：全部候选、分数降序、同分按扫描顺序")

local G14 = pingpongBoard(true)
local L14 = hint.findMoves(G14)
local R14 = hint.findMove(pingpongBoard(true))      -- 另造一副同构牌局

check("返回 table 且不止一个候选", type(L14) == "table" and #L14 > 1)
check("list[1] 与 findMove 完全一致", L14[1] ~= nil and R14 ~= nil
  and L14[1].from == R14.from and L14[1].index == R14.index
  and L14[1].to == R14.to and L14[1].count == R14.count
  and L14[1].score == R14.score and L14[1].flips == R14.flips)

check("分数不升（降序）", (function()
  for k = 2, #L14 do
    if L14[k - 1].score < L14[k].score then return false end
  end
  return true
end)())

-- 同分时按 (from, index, to) 升序 —— 这正是老 findMove「同分留先扫到的」语义，
-- 也是排序结果唯一（不依赖 table.sort 稳定性）的原因。
check("同分按 (from,index,to) 升序", (function()
  for k = 2, #L14 do
    local a, b = L14[k - 1], L14[k]
    if a.score == b.score then
      if a.from > b.from then return false end
      if a.from == b.from and a.index > b.index then return false end
      if a.from == b.from and a.index == b.index and a.to > b.to then return false end
    end
  end
  return true
end)())

check("没有重复的 (from,index,to)", (function()
  local seen = {}
  for _, m in ipairs(L14) do
    local key = m.from .. ":" .. m.index .. ":" .. m.to
    if seen[key] then return false end
    seen[key] = true
  end
  return true
end)())

check("每一个候选都真的合法", (function()
  for _, m in ipairs(L14) do
    local src, dst = G14.tableau[m.from], G14.tableau[m.to]
    if m.from == m.to then return false end
    if not rules.canPickUp(src, m.index) then return false end
    if #dst == 0 then
      if m.index <= 1 then return false end          -- 整列搬到空列不算走法
    elseif not rules.canDrop(dst, src[m.index].rank) then
      return false
    end
  end
  return true
end)())

check("逆向那一手沉到末尾且分数为负",
  #L14 > 1 and L14[#L14].from == 2 and L14[#L14].to == 1 and L14[#L14].score < 0)

check("没走法时返回空表而不是 nil", (function()
  local l = hint.findMoves(noMoveBoard())
  return type(l) == "table" and #l == 0
end)())

check("两次调用结果一致", (function()
  local a, b = hint.findMoves(pingpongBoard(true)), hint.findMoves(pingpongBoard(true))
  if #a ~= #b then return false end
  for k = 1, #a do
    if a[k].from ~= b[k].from or a[k].index ~= b[k].index or a[k].to ~= b[k].to then
      return false
    end
  end
  return true
end)())

check("findMoves 不修改牌局", (function()
  local g = game.new(2, makeRng(777))
  local before = game.dump(g)
  hint.findMoves(g)
  return game.dump(g) == before
end)())

check("status(g, list) 与 status(g) 结论一致",
  hint.status(pingpongBoard(true)) ==
  hint.status(pingpongBoard(true), hint.findMoves(pingpongBoard(true))))

-- 拿真实牌局一路走下去：每一步的 list[1] 必须等于 findMove，
-- 否则 states_smoke 里"第一次按 H 给最优解"就失去依据了。
check("真实牌局 200 步：list[1] 恒等于 findMove", (function()
  local g = game.new(4, makeRng(20261019))
  local bad = 0
  for _ = 1, 200 do
    local m = hint.findMove(g)
    local l = hint.findMoves(g)
    if (m == nil) ~= (l[1] == nil) then
      bad = bad + 1
    elseif m and (m.from ~= l[1].from or m.index ~= l[1].index or m.to ~= l[1].to) then
      bad = bad + 1
    end

    if m then
      game.tryMove(g, m.from, m.index, m.to)
    elseif not game.dealFromStock(g) then
      break
    end
  end
  return bad == 0
end)())

-- ===== 汇总 =====
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
