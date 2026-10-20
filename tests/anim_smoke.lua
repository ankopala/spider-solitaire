-- tests/anim_smoke.lua —— M8 终端验证脚本（动画事件 + 动画队列）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/anim_smoke.lua
--
-- 本脚本不依赖 LÖVE。
--
-- 动画最容易错的地方不是"画得不好看"，而是【动画反过来影响了规则】：
--   · 为了让牌飞得好看，让 game 记住时间 → 逻辑层被污染，终端测试跑不了；
--   · 动画期间状态被改了一半 → 玩家点到了"不存在的牌"；
--   · 收组动画拿的是牌对象引用，而牌已经被删掉 → 撤销之后画的是另一副牌。
-- 所以这里既验"偏移量算得对"，也验一条硬不变量：
--   **把队列里的动画从头播到尾，牌局的 dump 必须一个字都不变。**

local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const  = require("const")
local C      = require("src.card")
local layout = require("src.layout")
local anim   = require("src.anim")
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

local function near(a, b, eps)
  eps = eps or 1e-6
  return math.abs(a - b) <= eps
end

local function section(title)
  print("")
  print(title)
  print(string.rep("-", 62))
end

-- ===== 造牌工具 =====

local function one(suit, rank, faceUp)
  return C.new(suit, rank, faceUp ~= false)
end

-- high 递减到 low 的一串同花正面牌
local function run(suit, high, low)
  local out = {}
  for r = high, low, -1 do
    out[#out + 1] = C.new(suit, r, true)
  end
  return out
end

-- 手写空牌局（10 列都建成空表，避免 # 遇 nil）
local function emptyGame()
  local g = {
    tableau     = {},
    stock       = {},
    foundations = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 },
    difficulty  = 4,
    score       = const.SCORE_START,
    moves       = 0,
    selected    = nil,
    message     = "",
    rejectCol   = nil,
    history     = {},
    events      = {},
  }
  for i = 1, const.COLS do g.tableau[i] = {} end
  return g
end

local function pushAll(g, col, cards)
  for _, c in ipairs(cards) do
    g.tableau[col][#g.tableau[col] + 1] = c
  end
end

-- 把 g.events 全部倒进一个队列并清空（模拟 playing.lua 每帧做的事）
local function drain(g, q)
  for _, e in ipairs(g.events or {}) do
    anim.push(q, e)
  end
  g.events = {}
end

-- ===== 1. 缓动 =====
section("1. 缓动函数")

check("easeOutCubic(0) = 0", near(anim.easeOutCubic(0), 0))
check("easeOutCubic(1) = 1", near(anim.easeOutCubic(1), 1))
check("超出范围会被夹住（<0）", near(anim.easeOutCubic(-3), 0))
check("超出范围会被夹住（>1）", near(anim.easeOutCubic(9), 1))

-- 单调递增：动画不能倒退
local mono = true
local prev = -1
for i = 0, 20 do
  local v = anim.easeOutCubic(i / 20)
  if v < prev - 1e-9 then mono = false end
  prev = v
end
check("easeOutCubic 单调递增", mono)

-- ease-out 的特征：前半程走得比线性快
check("easeOutCubic(0.5) 明显超过一半", anim.easeOutCubic(0.5) > 0.8)
check("clamp01 上下都夹", anim.clamp01(-1) == 0 and anim.clamp01(2) == 1)
check("lerp 两端与中点", near(anim.lerp(10, 20, 0), 10)
  and near(anim.lerp(10, 20, 1), 20) and near(anim.lerp(10, 20, 0.5), 15))

-- ===== 2. 队列 =====
section("2. 队列：先进先出、一次只播一项")

local q = anim.queue()
check("新队列是空的", anim.active(q) == nil and anim.busy(q) == false)

local a = anim.push(q, { kind = "shift", dur = 0.2, groups = {
  { col = 1, first = 1, count = 1, dx = 0, dy = -50 },
} })
local b = anim.push(q, { kind = "collect", dur = 0.4, blocking = true, slot = 1, cards = {} })

check("push 之后 t = 0", a.t == 0)
check("shift 的总时长 = 最后一个 group 的 delay + dur（这里 0.2）", near(a.total, 0.2))
check("只有队头是 active", anim.active(q) == a)
check("非 blocking 不拦输入", anim.busy(q) == false)

-- 播放中
anim.update(q, 0.08)
check("update 推进 t", near(a.t, 0.08))
check("还没播完，队头不变", anim.active(q) == a)

-- 播完：返回刚播完的那一项，队头换人
local done = anim.update(q, 0.2)
check("播完返回该项", done == a)
check("队头换成第二项", anim.active(q) == b)
check("collect 会拦输入", anim.busy(q) == true)
check("collecting 认出队列里有收组", anim.collecting(q) == true)

-- 掉帧：一帧跨过整项，剩余 dt 应继续作用到下一项，而不是丢帧
anim.update(q, 0.1)
anim.clear(q)
local c1 = anim.push(q, { kind = "shift", dur = 0.1, groups = { { col = 1, first = 1, count = 1, dx = 0, dy = 0 } } })
local c2 = anim.push(q, { kind = "shift", dur = 0.4, groups  = { { col = 1, first = 1, count = 1, dx = 0, dy = 0 } } })
anim.update(q, 0.15)                       -- 0.1 用完，剩 0.05 给第二项
check("一项播完后 dt 有结余给下一项（不会整体变慢）", near(c2.t, 0.05, 1e-9))
check("第一项已经出队", anim.active(q) == c2)

-- reset 指令
local qr = anim.queue()
anim.push(qr, { kind = "shift", dur = 1, groups = { { col = 1, first = 1, count = 1, dx = 0, dy = 0 } } })
anim.push(qr, { kind = "reset" })
check("reset 会清空队列", #qr.items == 0 and anim.active(qr) == nil)

-- ===== 3. shiftFor：卡牌偏移 =====
section("3. shiftFor：一张牌该在哪")

local it = anim.push(anim.queue(), {
  kind = "shift", dur = 0.2, groups = {
    { col = 2, first = 3, count = 2, dx = 10, dy = -100, delay = 0.05 },
  },
})

check("延迟还没到 → 这一张不画（hide）", (function()
  local sh = anim.shiftFor(it, 2, 3)
  return sh ~= nil and sh.hide == true
end)())
check("没被 group 覆盖的牌 → 无偏移", anim.shiftFor(it, 1, 3) == nil)
check("同一列但索引不在范围内 → 无偏移", anim.shiftFor(it, 2, 5) == nil)

it.t = 0.05                                          -- 手动对齐：刚好到 delay
local sh0 = anim.shiftFor(it, 2, 3)
check("刚到 delay → 停在起点（偏移 = 全量）", sh0 ~= nil and near(sh0.dx, 10) and near(sh0.dy, -100))
check("count = 2 覆盖第 3、4 张", anim.shiftFor(it, 2, 4) ~= nil)
check("第 5 张仍不覆盖", anim.shiftFor(it, 2, 5) == nil)

it.t = 0.05 + 0.1                                    -- 半程
local shMid = anim.shiftFor(it, 2, 3)
check("半程偏移在 0 和全量之间", shMid ~= nil and shMid.dy > -100 and shMid.dy < 0)

it.t = 0.05 + 0.2                                    -- 到点
check("播完 → 无偏移（回到最终位置）", anim.shiftFor(it, 2, 3) == nil)

-- ===== 4. 开局发牌 =====
section("4. 开局：54 张牌依次落下")

math.randomseed(20261019)
local rng = function(n) return math.random(n) end
local g0 = game.new(1, rng)

check("开局带了一条动画事件", #g0.events == 1)
local op = g0.events[1]
check("事件 kind = shift", op.kind == "shift")
check("开局动画拦输入", op.blocking == true)
check("54 个 group（4 列 ×6 + 6 列 ×5）", #op.groups == 54)

-- 每张牌正好被覆盖一次
local seen, dup = {}, false
for _, gr in ipairs(op.groups) do
  for k = gr.first, gr.first + gr.count - 1 do
    local key = gr.col .. ":" .. k
    if seen[key] then dup = true end
    seen[key] = true
  end
end
local seenCount = 0
for _ in pairs(seen) do seenCount = seenCount + 1 end
check("没有重复覆盖", dup == false)
check("覆盖的正好是 54 张", seenCount == 54)

-- 延迟必须递增（依次落下，而不是一起砸下来）
local increasing = true
for i = 2, #op.groups do
  if op.groups[i].delay <= op.groups[i - 1].delay then increasing = false end
end
check("delay 严格递增", increasing)

local lastDelay = op.groups[#op.groups].delay
check("整段发牌在 1.3s 内结束", lastDelay + op.dur <= 1.3)

-- 落点必须和 layout 算出来的一致。
-- 约定是 dy = 【起点 - 终点】，所以「最终 y + dy」必须处处等于同一个锚点 y。
-- 早先这里符号写反过，牌就变成从下方升上来 —— 这个断言就是拦它的。
local anchor, anchorOK = nil, true
for _, gr in ipairs(op.groups) do
  local ay = layout.cardY(g0.tableau[gr.col], gr.first) + gr.dy
  if not anchor then anchor = ay end
  if math.abs(ay - anchor) > 1e-9 then anchorOK = false end
end
check("所有 group 从同一个锚点（屏幕上方）出发", anchorOK)
check("锚点在屏幕上方（从外面落下来，不是从下面升上来）", anchor < 0)

-- ===== 5. 移动 =====
section("5. 移动：整段一个 dy")

local gm = emptyGame()
pushAll(gm, 1, { one("spades", 8) })                        -- 单张 8♠
pushAll(gm, 2, { one("spades", 10), one("hearts", 9) })     -- 10♠ 上压 9♥
gm.selected = { col = 1, index = 1 }

local oldY = layout.cardY(gm.tableau[1], 1)
local ok = game.tryMove(gm, 1, 1, 2)
check("移动成功", ok == true)
check("产生一条事件", #gm.events == 1)

local ev = gm.events[1]
check("kind = shift", ev.kind == "shift")
check("不拦输入（否则连续出牌会卡手）", ev.blocking ~= true)
check("只覆盖目标列的那一张", #ev.groups == 1 and ev.groups[1].col == 2
  and ev.groups[1].first == 3 and ev.groups[1].count == 1)

local newY = layout.cardY(gm.tableau[2], 3)
check("dy = 旧 y - 新 y", near(ev.groups[1].dy, oldY - newY))
check("这个例子里正好下落两张牌的间距", near(ev.groups[1].dy, -2 * const.STEP_UP))

-- 多张一起移动：count 正确、dy 仍然只有一个
local gm2 = emptyGame()
pushAll(gm2, 1, { one("spades", 10), one("spades", 9), one("spades", 8) })
pushAll(gm2, 2, { one("spades", 11) })
gm2.selected = { col = 1, index = 1 }
game.tryMove(gm2, 1, 1, 2)
check("三张一起移动 → count = 3", gm2.events[1].groups[1].count == 3)

-- 失败的移动不该产生任何动画
local gm3 = emptyGame()
pushAll(gm3, 1, { one("spades", 5) })
pushAll(gm3, 2, { one("spades", 13) })
gm3.selected = { col = 1, index = 1 }
game.tryMove(gm3, 1, 1, 2)
check("被拒绝的移动不产生动画", #gm3.events == 0)

-- 凑成一组的移动：只播收组，不播移动。
-- 否则移动动画覆盖的 13 张已经被删掉，等于 0.15 秒里什么都不显示，
-- 然后整组突然起飞 —— 那一下很像是卡住了。
local gset = emptyGame()
pushAll(gset, 1, run("spades", 13, 2))                      -- K..2
pushAll(gset, 2, { one("hearts", 5), one("spades", 1) })    -- 顶部 A♠
gset.selected = { col = 2, index = 2 }
local okSet = game.tryMove(gset, 2, 2, 1)
check("凑成一组的移动成功", okSet == true)
check("只产生一条事件（不排队移动动画）", #gset.events == 1)
check("那一条是收组", gset.events[1].kind == "collect")
check("收组落在第 1 槽", gset.events[1].slot == 1)

-- 用队列播一遍：起点必须是旧位置
local qm = anim.queue()
drain(gm, qm)
local im = anim.active(qm)
local shStart = anim.shiftFor(im, 2, 3)
check("t = 0 时停在旧位置（偏移 = dy）", shStart ~= nil and near(shStart.dy, oldY - newY))
anim.update(qm, 0.075)
check("半程在动", anim.shiftFor(im, 2, 3) ~= nil)
anim.update(qm, 0.2)
check("播完动画就从队列里消失", anim.active(qm) == nil)

-- ===== 6. 补牌 =====
section("6. 补牌：10 张从 stock 依次飞出")

local gs = emptyGame()
for i = 1, const.COLS do pushAll(gs, i, { one("hearts", 5) }) end
for k = 1, 20 do gs.stock[k] = one("spades", (k % 13) + 1, false) end

local okDeal = game.dealFromStock(gs)
check("补牌成功", okDeal == true)
check("产生一条事件", #gs.events == 1)

local dev = gs.events[1]
check("10 个 group", #dev.groups == const.COLS)
check("每个 group 覆盖一列的最后一张", (function()
  for i, gr in ipairs(dev.groups) do
    if gr.col ~= i or gr.first ~= #gs.tableau[i] or gr.count ~= 1 then return false end
  end
  return true
end)())

check("起点就是 stock 的 x", near(dev.groups[1].dx, const.STOCK_X - const.colX(1)))
check("delay 从左到右递增", (function()
  for i = 2, #dev.groups do
    if dev.groups[i].delay <= dev.groups[i - 1].delay then return false end
  end
  return true
end)())

-- ===== 7. 收组 =====
section("7. 收组：13 张飞进 foundation")

local gc = emptyGame()
pushAll(gc, 1, run("spades", 13, 1))          -- 完整一组 K..A
gc.foundations.spades = 2                      -- 前面已经收过 2 组 → 这组落第 3 槽

local res = game.collectCompleteSets(gc)
check("收掉一组", res.count == 1)
check("牌已经从列里消失（动画画的是副本）", #gc.tableau[1] == 0)
check("产生一条事件", #gc.events == 1)

local cev = gc.events[1]
check("kind = collect", cev.kind == "collect")
check("收组拦输入", cev.blocking == true)
check("13 张牌面", #cev.cards == 13)
check("牌面是 K→A（和列里的上下顺序一致）",
  cev.cards[1].rank == 13 and cev.cards[13].rank == 1)
check("落在第 3 个槽", cev.slot == 3)
check("落点 x = 第 3 槽的 x", near(cev.x1, const.foundSlotX(3)))
check("落点 y = foundation 的 y", near(cev.y1, const.FOUND_Y))
check("缩放 = 槽宽 / 牌宽", near(cev.s, const.FOUND_W / const.CARD_W))
check("起始就是列尾第一张的位置",
  near(cev.y0, const.TABLEAU_Y) and near(cev.x0, const.colX(1)))

-- 起点若算错，就会看到牌从半空中冒出来飞走
check("起始 y 对应 K 的位置（不是 A 的）",
  near(cev.y0, layout.cardY({ run("spades", 13, 1) }, 1)))

-- 播完之后：13 张完全重叠在槽上（step1 = 0）
local qc = anim.queue()
anim.push(qc, cev)
local p = anim.collectProgress(cev)
check("t = 0 时进度为 0", near(p, 0))
anim.update(qc, cev.dur / 2)
local pmid = anim.collectProgress(cev)
check("半程进度在 0 和 1 之间", pmid > 0 and pmid < 1)
check("半程已经缩小", anim.lerp(1, cev.s, pmid) < 1 and anim.lerp(1, cev.s, pmid) > cev.s)

-- ===== 8. 撤销 =====
section("8. 撤销：动画必须立刻作废")

local gu = emptyGame()
pushAll(gu, 1, { one("spades", 9) })
pushAll(gu, 2, { one("spades", 10) })
gu.selected = { col = 1, index = 1 }
game.tryMove(gu, 1, 1, 2)

local qu = anim.queue()
drain(gu, qu)
check("先排进一条移动动画", #qu.items == 1)

game.undo(gu)
check("撤销产生 reset 指令", #gu.events == 1 and gu.events[1].kind == "reset")
drain(gu, qu)
check("reset 把在飞的动画清掉了", #qu.items == 0)
check("牌已经回到原列", #gu.tableau[1] == 1 and #gu.tableau[2] == 1)

-- ===== 9. 硬不变量：动画不改牌局 =====
section("9. 不变量：把动画播完，牌局一个字都不能变")

math.randomseed(777)
local gx = game.new(4, rng)
local qx = anim.queue()

local before = game.dump(gx)
drain(gx, qx)
-- 一直播到队列空（最多 5 秒）
local t = 0
while anim.active(qx) and t < 5 do
  anim.update(qx, 1 / 60)
  t = t + 1 / 60
end
local after = game.dump(gx)

check("开局动画播完，dump 完全一致", before == after)
check("开局动画在 5 秒内确实播完了", anim.active(qx) == nil)

-- 随机走 200 步，每步都把动画播完，检查牌数守恒 + dump 稳定
local SUITS = { "spades", "hearts", "diamonds", "clubs" }

local function totalCards(g)
  local n = #g.stock
  for i = 1, const.COLS do n = n + #g.tableau[i] end
  for _, suit in ipairs(SUITS) do
    n = n + (g.foundations[suit] or 0) * 13
  end
  return n
end

local stable, conserved = true, true
for step = 1, 200 do
  -- 随机挑一列非空的牌，点它列尾那张 → 选中
  local from = math.random(const.COLS)
  local guard = 0
  while #gx.tableau[from] == 0 and guard < 20 do
    from = math.random(const.COLS)
    guard = guard + 1
  end

  if #gx.tableau[from] > 0 then
    local col = gx.tableau[from]
    local cx  = const.colX(from) + const.CARD_W / 2
    local cy  = layout.cardY(col, #col) + const.CARD_H / 2
    game.clickAt(gx, cx, cy)

    -- 再随便挑一个别的列当落点
    local to = math.random(const.COLS)
    if to ~= from then game.dropAt(gx, to) end
  end

  local d0 = game.dump(gx)
  drain(gx, qx)
  local g2 = 0
  while anim.active(qx) and g2 < 400 do
    anim.update(qx, 1 / 60)
    g2 = g2 + 1
  end
  if anim.active(qx) then stable = false end     -- 动画卡死
  if game.dump(gx) ~= d0 then stable = false end -- 动画改了牌局
  if totalCards(gx) ~= 104 then conserved = false end
end

check("200 次随机操作，动画从不修改牌局", stable)
check("200 次随机操作，始终 104 张牌", conserved)

-- ===== 汇总 =====
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
