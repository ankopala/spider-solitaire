-- src/game.lua —— 牌局状态与操作（M3 移动 / M4 补牌 / M5 成组消除 / M7 撤销 / M8 动画事件）
--
-- 【重要】本文件不引用 love：所有判断走 src.rules、所有坐标走 src.layout，
-- 因此整条「点击 → 选中 → 移动 → 收组 → 撤销」的链路都能在终端用普通 Lua 跑测试。
--
-- 它管七件事：
--   1. 牌局对象 game 的构造（发牌 + 计分/步数/选中态）
--   2. 点击语义：把一次鼠标点击翻译成「选中 / 移动 / 补牌 / 撤销 / 取消」
--   3. 真正搬牌（只搬 table 引用，不复制牌对象）
--   4. 从 stock 补牌（M4）
--   5. 扫描列尾的 K→A 同花序列，收进 foundation（M5）
--   6. 撤销栈：改动牌桌之前压一份深拷贝快照（M7）
--   7. 往 g.events 里记「刚发生了什么」（M8，纯数据，给界面播动画）
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local const  = require("const")
local card   = require("src.card")
local deck   = require("src.deck")
local layout = require("src.layout")
local rules  = require("src.rules")

local M = {}

-- HUD 上的提示文字用英文：当前字体 DejaVu Sans 不含 CJK，中文会显示成方框。
-- （终端 stdout 不受影响，M6 再统一决定中文方案。）

local function say(g, msg)
  g.message = msg
  return msg
end

-- ===== 动画事件（M8）=====
--
-- 【为什么要走"事件"而不是让 game 直接播动画】
--   game.lua 是纯逻辑、能在终端跑；它一旦认识时间、认识 love.graphics 就废了。
--   所以它只负责【描述】刚发生的事，具体怎么演交给 src/anim.lua + src/render.lua。
--
-- 事件里带的是【坐标】而不是牌对象：牌都已经挪走了，位置得在挪走之前先量下来。
local function emit(g, e)
  if not g.events then g.events = {} end
  g.events[#g.events + 1] = e
  return e
end


-- ===== 构造 =====

-- 开一局新牌
function M.new(difficulty, rng, seed)
  local g = deck.dealNewGame(difficulty, rng)
  -- 这一局的身份证。同一个 (seed, difficulty) 一定发回同一副牌。
  -- 可选参数：老调用不传就是 nil，显示时按"没有种子"处理。
  g.seed      = seed
  g.score     = const.SCORE_START   -- 微软经典计分：初始 500
  g.moves     = 0
  g.selected  = nil          -- { col = 4, index = 3 } 当前选中的序列起点
  g.message   = ""           -- 最近一步的结果，给 HUD 显示
  g.rejectCol = nil          -- 最近一次"落点被拒"的列号（给界面描红用）
  g.history   = {}           -- 撤销栈（M7）：每份都是改动前的深拷贝快照
  g.events    = {}           -- 动画事件（M8）：界面每帧取走，不参与快照
  g.lastMove  = nil          -- 上一步 {from, to}：给 hint 用来识别"原路搬回去"

  -- 开局快照（认输后"同一副牌重开"要用）。
  -- ⚠ 必须是【深拷贝】：牌桌后面会被反复改动，直接贴引用会把它一起改掉。
  -- snapshot 只取 tableau/stock/foundations/score/moves，不含 history/events，
  -- 所以它天生就是"一副干净的初始牌"，重开时拿它再拷一份即可。
  g.initial = M.snapshot(g)

  -- 开局那 54 张是 deck.lua 一次性摆好的。这里补一条"它们是怎么落下来的"记录，
  -- 让界面把开局演成发牌，而不是开局就是一副静止的牌。
  emit(g, M.openingAnim(g))
  return g
end

-- 用【同一副牌】重新开始：牌序、每张牌的翻开状态、stock 顺序全部和开局一致。
--
-- 为什么不是"记住随机种子再洗一次"？因为那样要求随机源可复现（LÖVE 的
-- love.math 每帧都在被别处消耗），而且改一行 deck 代码就可能让旧种子失效。
-- 直接留一份初始快照最稳：以后哪怕换了洗牌算法，旧局也照样能重开。
function M.restart(g)
  if not g.initial then return g end

  -- 从 initial 再深拷一份：initial 本身要留着，玩家可以反复重开。
  local s = M.snapshot(g.initial)

  g.tableau     = s.tableau
  g.stock       = s.stock
  g.foundations = s.foundations
  g.score       = const.SCORE_START
  g.moves       = 0
  g.history     = {}
  g.selected    = nil
  g.rejectCol   = nil
  g.lastMove    = nil
  g.events      = {}

  -- 重开也演一遍发牌：不用额外做"重置"动画，牌从上方落回来本身就是重置感。
  emit(g, M.openingAnim(g))
  return g
end

-- 开局发牌动画：54 张牌从屏幕上方依次落到各自的位置。
--
-- 排序按【轮】而不是按【列】：deck.dealNewGame 实际是一列一列发的，
-- 但一列一列地演会变成"左边刷一下、右边刷一下"；按轮交叉发才像真人发牌，
-- 看上去是一道从左到右扫过的波。
--
-- 落点【垂直落下】（dx = 0）：早先的版本让所有牌从屏幕正中飞向各自列，
-- 54 张在半路上会横穿十几列，画面糊成一团。垂直落下干净得多。
-- 落点完全由 layout.cardY 算，所以这个动画不会和真实牌位错开。
function M.openingAnim(g)
  local anchorY = -const.CARD_H - 30           -- 从屏幕上方外面掉进来

  local longest = 0
  for i = 1, const.COLS do
    if #g.tableau[i] > longest then longest = #g.tableau[i] end
  end

  local groups, n = {}, 0
  for k = 1, longest do
    for i = 1, const.COLS do
      local col = g.tableau[i]
      if col[k] then
        groups[#groups + 1] = {
          col   = i,
          first = k,
          count = 1,
          dx    = 0,
          -- ⚠ 符号是【起点 - 终点】。render 的算法是「画在 终点 + (起点-终点) × 剩余比例」，
          -- 所以这里给反了的话牌会从下方往上升，而不是从上方落下来。
          dy    = anchorY - layout.cardY(col, k),
          delay = n * const.ANIM_DEAL_STAGGER,
        }
        n = n + 1
      end
    end
  end

  return {
    kind     = "shift",
    dur      = const.ANIM_DEAL_CARD,
    blocking = true,        -- 发牌期间不接受操作，否则会点在一副还没发完的牌上
    groups   = groups,
  }
end

function M.deselect(g)
  g.selected  = nil
  g.rejectCol = nil
end

-- ===== 查询：当前选中能落到哪些列 =====

-- 返回一个数组，元素是「可以落」的列号（给界面描边用）。
-- 这件事必须和 tryMove 用同一份规则判断，否则会出现"界面说能放、实际放不下"。
function M.legalTargets(g)
  local out = {}
  local sel = g.selected
  if not sel then return out end

  local src = g.tableau[sel.col]
  if not src or not src[sel.index] then return out end

  local rank = src[sel.index].rank
  for j = 1, const.COLS do
    if j ~= sel.col and rules.canDrop(g.tableau[j], rank) then
      out[#out + 1] = j
    end
  end
  return out
end

-- 当前选中的是哪几张（给界面/调试用）
function M.selectionInfo(g)
  local sel = g.selected
  if not sel then return nil end

  local src = g.tableau[sel.col]
  if not src or not src[sel.index] then return nil end

  return {
    col   = sel.col,
    index = sel.index,
    count = rules.sequenceLength(src, sel.index),
    card  = src[sel.index],
  }
end

-- ===== 成组消除 + 胜利（M5）=====
--
-- 蜘蛛纸牌里「完成一组」是自动的：只要某列列尾凑出同花 K→A，这 13 张立刻被收走，
-- 不需要玩家点什么。所以它插在【每一次可能改变牌桌的动作之后】：
--   · 成功移动一段牌之后（移过去刚好补齐）
--   · 补牌之后（补上来的那张刚好补齐）
--
-- 收走时的那点细节，漏了会很难受：
--   · 13 张从列尾删掉后，如果列的【新顶牌】还是背面，要自动翻开 ——
--     否则玩家会看到一整列背面牌却无从下手；
--   · 一次动作理论上可能触发【连锁】（极少见但存在），所以每列用 while 循环反复查。

-- 已经完成几组（0..8）
function M.foundationTotal(g)
  local n = 0
  for _, suit in ipairs(card.SUITS) do
    n = n + (g.foundations[suit] or 0)
  end
  return n
end

-- 赢了吗？8 组全收完
function M.isWon(g)
  return M.foundationTotal(g) >= const.FOUND_COUNT
end

-- 扫描全部 10 列，把列尾凑成的同花 K→A 收进 foundation。
-- 返回 { count = 收了几组, suits = { 花色, ... } }。
-- 【不写 g.message】—— 由调用方（tryMove / dealFromStock）把结果拼进自己那句话里，
-- 否则这里一 say 就会把"移动了几个牌"的提示覆盖掉。
function M.collectCompleteSets(g)
  local count = 0
  local suits = {}

  for i = 1, const.COLS do
    local col = g.tableau[i]

    while true do
      local suit = rules.completeSetSuit(col)
      if not suit then break end

      -- --- 动画事件（M8）---
      -- 必须在删牌【之前】把牌面和起点量下来：这 13 张马上就要从列里消失，
      -- 之后 render 只能靠这份记录把它们画出来、飞进 foundation。
      local n0   = #col
      local slot = M.foundationTotal(g) + 1        -- 收完这一组会落在第几个槽
      local face = {}
      for k = n0 - 12, n0 do
        face[#face + 1] = { suit = col[k].suit, rank = col[k].rank }
      end
      emit(g, {
        kind     = "collect",
        dur      = const.ANIM_COLLECT,
        blocking = true,          -- 收组是这一局的高光，值得让玩家看完
        slot     = slot,
        cards    = face,          -- K 在前、A 在后（和列里的上下顺序一致）
        x0       = const.colX(i),
        y0       = layout.cardY(col, n0 - 12),
        x1       = const.foundSlotX(slot),
        y1       = const.FOUND_Y,
        s        = const.FOUND_W / const.CARD_W,    -- 缩到 foundation 槽那么大
        step0    = const.STEP_UP,                   -- 起始时按列里的叠压间距
        step1    = 0,                               -- 落槽时完全重叠成一张
      })

      -- 从列尾删 13 张（删的正好是列尾，不需要关心索引重排）
      for _ = 1, 13 do
        table.remove(col)
      end

      g.foundations[suit] = (g.foundations[suit] or 0) + 1
      g.score = g.score + const.SCORE_PER_SET
      count = count + 1
      suits[#suits + 1] = suit

      -- 收走之后露出来的新顶牌若是背面 → 翻开
      if #col > 0 and not col[#col].faceUp then
        col[#col].faceUp = true
      end
    end
  end

  -- 万一选中态正指着刚被收走的位置（正常不会，因为调用方随后都会 deselect），
  -- 这里兜一下，避免界面拿到一个已经不存在的位置。
  if g.selected then
    local col = g.tableau[g.selected.col]
    if not col or not col[g.selected.index] then
      M.deselect(g)
    end
  end

  return { count = count, suits = suits }
end

-- 把收组结果拼成一句话的尾巴（没有收组就返回空串）
local function setsPhrase(res)
  if not res or res.count == 0 then return "" end

  local glyphs = {}
  for _, s in ipairs(res.suits) do
    glyphs[#glyphs + 1] = card.suitGlyph(s)
  end

  return string.format(" + completed %d set%s %s (+%d)",
    res.count, res.count > 1 and "s" or "",
    table.concat(glyphs, " "), res.count * const.SCORE_PER_SET)
end

-- ===== 撤销（M7）=====
--
-- 方案：**改动之前深拷贝一份快照**压进 g.history 栈。比"记录反向操作"简单得多，
-- 而且天然覆盖了那些"顺手改了别的东西"的情况 —— 一次移动可能刚好补齐一组，
-- 收组会同时改 foundations / score / 列里的 13 张牌，反向操作极难写全；快照一起回滚。
--
-- ⚠ undo 最常见的坑是【只复制了 table 外壳、没复制牌本身】：
--   那样快照里的牌和正在玩的牌还是同一个 table，撤销回去再翻面/移动，
--   会把快照内容一起改脏 —— 下一次撤销就再也回不到原样了。
--   所以 copyCard 必须逐字段重建牌对象（不是 `t[k] = c`）。
--
-- 另一条：**快照必须在"确定要改"之后、真正改之前压**。
--   压早了会把被拒绝的点击也记成一步，玩家按撤销会觉得"什么都没撤销"。

local HISTORY_MAX = 100        -- 栈上限，防止长局无限膨胀（每份 ~104 张小表，仍然很轻）

-- 逐字段复制一张牌。用 pairs 而不是写死 suit/rank/faceUp，
-- 以后牌对象多出字段（id、贴图索引之类）时快照自动跟上。
local function copyCard(c)
  local t = {}
  for k, v in pairs(c) do t[k] = v end
  return t
end

-- 造一份当前牌局的深拷贝快照
function M.snapshot(g)
  local s = {
    tableau     = {},
    stock       = {},
    foundations = {},
    score       = g.score,
    moves       = g.moves,
  }

  for i = 1, const.COLS do
    local src = g.tableau[i]
    local dst = {}
    for k = 1, #src do dst[k] = copyCard(src[k]) end
    s.tableau[i] = dst
  end

  for k = 1, #g.stock do s.stock[k] = copyCard(g.stock[k]) end

  for _, suit in ipairs(card.SUITS) do
    s.foundations[suit] = g.foundations[suit] or 0
  end

  return s
end

-- 压栈
function M.pushHistory(g)
  if not g.history then g.history = {} end
  g.history[#g.history + 1] = M.snapshot(g)

  -- 超上限丢最老的一份。table.remove(t, 1) 会重排索引，但栈很小，不值得为它做环形缓冲。
  while #g.history > HISTORY_MAX do
    table.remove(g.history, 1)
  end
end

-- 还能撤销几步（界面用它决定按钮亮不亮）
function M.undoDepth(g)
  if not g.history then return 0 end
  return #g.history
end

function M.canUndo(g)
  return M.undoDepth(g) > 0
end

-- 撤销一步。返回一句描述（和其它操作一样走 g.message）。
function M.undo(g)
  if not M.canUndo(g) then
    return say(g, "nothing to undo")
  end

  local snap = table.remove(g.history)

  -- 直接把快照里的表接管过来。快照已经出栈，不会被第二次读，
  -- 所以之后对牌的改动（翻面、移动）不会污染历史 —— 每份快照都是独立的深拷贝。
  g.tableau     = snap.tableau
  g.stock       = snap.stock
  g.foundations = snap.foundations
  g.moves       = snap.moves

  -- 分数：先回滚到快照，再扣掉撤销本身的 1 分。
  -- 也就是说撤销【不会】把移动扣掉的那 1 分退回来 —— 否则可以靠"移动+撤销"刷分。
  g.score = snap.score - const.SCORE_PER_UNDO

  -- 撤销之后"上一步"已经被抹掉了，hint 不该再拿它判往返。
  g.lastMove = nil

  -- 动画（M8）：撤销会把牌瞬间放回原位。正在播的"移动/收组"动画必须立刻作废，
  -- 否则会看到牌从刚飞过去的地方又飞回来，而且落点是按已作废的状态算的。
  emit(g, { kind = "reset" })

  M.deselect(g)

  -- 提示里带上"还剩几步可撤"，玩家不用猜是不是撤到头了
  local left = #g.history > 0 and string.format(", %d more", #g.history) or ""
  return say(g, string.format("undo  [moves %d, score %d%s]", g.moves, g.score, left))
end

-- ===== 点击语义 =====

-- 处理一次点击（参数是【虚拟坐标】）。返回一句描述结果的话（可能为空串）。
--
-- 判定顺序：先看有没有点在具体某张牌上（精确），再看落在哪一列的落点带里（宽容）。
-- 注意：落点带是 M3 的修复点 —— 点在目标列"牌下方的空白"里也要算落到那一列。
function M.clickAt(g, vx, vy)
  -- 已经赢了就不再接受操作：免得玩家在结算画面上继续点、把牌桌又搅乱。
  -- （重新开一局走 main.lua 的 R 键，M6 会换成 won 状态的按钮。）
  if M.isWon(g) then
    return say(g, "you won!  press R to deal a new game")
  end

  g.rejectCol = nil                          -- 每次新点击先清掉上一次的"被拒"标记

  -- 撤销按钮（M7）：底部那块按钮。它不在牌桌落点带里，所以必须先于其它判定。
  if layout.hitTestUndo(vx, vy) then
    return M.undo(g)
  end

  local col, index = layout.hitTestTableau(g, vx, vy)
  if col then
    return M.clickCard(g, col, index)
  end

  -- 牌库：点一下就补一轮（10 列各补 1 张）。M4 加的。
  -- 注意 clickAt 的契约是"只返回一句提示"，所以这里只取第二个返回值。
  if layout.hitTestStock(vx, vy) then
    local _, msg = M.dealFromStock(g)
    return msg
  end

  local band = layout.columnBandAt(vx, vy)
  if band then
    return M.clickColumnBand(g, band)
  end

  -- 点在牌桌以外（HUD / 牌库 / 底部）→ 取消选择
  if g.selected then
    M.deselect(g)
    return say(g, "deselected")
  end
  return ""
end

-- 尝试在 (col, index) 处建立选中态
function M.trySelect(g, col, index)
  local c = g.tableau[col][index]
  if not c.faceUp then
    return say(g, "face-down card, can't pick up")
  end
  if not rules.canPickUp(g.tableau[col], index) then
    return say(g, "not a same-suit descending run")
  end

  g.selected  = { col = col, index = index }
  g.rejectCol = nil
  local n = rules.sequenceLength(g.tableau[col], index)
  return say(g, string.format("picked %d card%s from col %d (%s)",
    n, n > 1 and "s" or "", col, card.label(c)))
end

-- 点在某张具体的牌上
function M.clickCard(g, col, index)
  local sel = g.selected

  -- 还没选东西 → 尝试选中一段
  if sel == nil then
    return M.trySelect(g, col, index)
  end

  -- 又点在自己刚选的那张上 → 反悔，取消选择
  if sel.col == col and sel.index == index then
    M.deselect(g)
    return say(g, "deselected")
  end

  -- 同一列里点了另一张 → 改成从新位置起选（不是移动）。
  -- 但如果那一张拿不起来（背面 / 不是同花降序），【保留原选择】只给提示 ——
  -- 老版本会直接取消选中，用户得重新选一次，手感很差。
  if sel.col == col then
    local c = g.tableau[col][index]
    if not c.faceUp then
      return say(g, "face-down card, can't pick up")
    end
    if not rules.canPickUp(g.tableau[col], index) then
      return say(g, "not a same-suit descending run")
    end
    return M.trySelect(g, col, index)
  end

  -- 点到别的列 → 尝试移动过去
  local _, msg = M.tryMove(g, sel.col, sel.index, col)
  return msg
end

-- 点在某列的落点带里（可能是空列，也可能是牌下方的空白）
function M.clickColumnBand(g, col)
  local sel = g.selected
  if sel == nil then
    -- 空列上没牌可选；牌下方的空白也一样。给一句提示，别让用户以为程序死了。
    return say(g, "no card selected - click a face-up card first")
  end
  local _, msg = M.tryMove(g, sel.col, sel.index, col)
  return msg
end

-- 保留旧名字，M4/M8 或外部脚本可能还在用
M.clickColumnSlot = M.clickColumnBand

-- 拖拽落点（M3 加）：鼠标在别的列上松开时调用，语义等同"点那一列的落点带"
function M.dropAt(g, col)
  return M.clickColumnBand(g, col)
end

-- ===== 移动 =====

-- 把 fromCol 从 fromIndex 起到列尾的那一段，搬到 toCol
-- 返回 ok, 描述。失败时【保留选中态】并把 toCol 记进 g.rejectCol，
-- 这样用户可以立刻换个落点重试，而不是被迫重新选牌。
function M.tryMove(g, fromCol, fromIndex, toCol)
  local src = g.tableau[fromCol]
  local dst = g.tableau[toCol]

  -- 没有选中的东西 / 索引越界
  if not src or not src[fromIndex] then
    M.deselect(g)
    return false, say(g, "nothing to move")
  end

  if fromCol == toCol then
    return false, say(g, "same column - drop it somewhere else")
  end

  if not rules.canPickUp(src, fromIndex) then
    M.deselect(g)
    return false, say(g, "that run can't move as a group")
  end

  local movingRank = src[fromIndex].rank
  if not rules.canDrop(dst, movingRank) then
    g.rejectCol = toCol                      -- 给界面描红：这一列不行
    local top = rules.topCard(dst)
    return false, say(g, string.format("can't drop on %s (needs rank %d or empty column)",
      top and card.label(top) or "empty", movingRank + 1))
  end

  -- --- 搬牌 ---
  -- 到这里这次移动一定成功，所以在【改任何东西之前】压一份快照（M7）。
  M.pushHistory(g)

  -- 动画（M8）：先量下这一段的旧 y —— 搬完之后原列就变短了，算不回来。
  local oldY = layout.cardY(src, fromIndex)

  -- 先按原顺序取出这一段（只搬引用，不复制牌对象）
  local moving = {}
  for i = fromIndex, #src do
    moving[#moving + 1] = src[i]
  end
  -- 再从后往前删：正序删会因索引重排而漏删（新手坑 #4）
  for _ = #src, fromIndex, -1 do
    table.remove(src)
  end
  -- 按原顺序追加到目标列尾部
  for _, c in ipairs(moving) do
    dst[#dst + 1] = c
  end

  -- 动画（M8）：这段牌在目标列的新位置。因为一段牌内部间距不变，
  -- 整段只需要一个统一的 dy —— 这也是为什么不用逐张记坐标。
  --
  -- 但如果这一下刚好凑齐了一组，就【不】播移动动画：收组会立刻把这 13 张
  -- 从列里删掉，移动动画覆盖的索引已经不存在，等于 0.15 秒里什么都不显示，
  -- 然后整组突然起飞。直接播收组更连贯 —— 那张刚落下的牌本来就是飞走那一叠的底张。
  local firstNew = #dst - #moving + 1
  local newY     = layout.cardY(dst, firstNew)
  if not rules.completeSetSuit(dst) then
    emit(g, {
      kind   = "shift",
      dur    = const.ANIM_MOVE,
      groups = {
        { col = toCol, first = firstNew, count = #moving, dx = 0, dy = oldY - newY },
      },
    })
  end

  -- --- 翻开暴露出来的新顶牌（若还是背面）---
  local flipped = false
  if #src > 0 and not src[#src].faceUp then
    src[#src].faceUp = true
    flipped = true
  end

  -- --- 计分 ---
  g.moves = g.moves + 1
  g.score = g.score - const.SCORE_PER_MOVE  -- 每成功移动一次 -1

  -- 记下这一手去了哪两列：hint 靠它认出"原路搬回去"的无意义往返。
  -- （必须在移动【之后】写，写的是"从哪搬到哪"的真实方向）
  g.lastMove = { from = fromCol, to = toCol }

  -- --- 成组消除（M5）---
  -- 必须放在"搬牌 + 翻牌"之后：这一步移动可能刚好把列尾补齐成 K→A。
  local sets = M.collectCompleteSets(g)

  M.deselect(g)

  return true, say(g, string.format("moved %d card%s (%s) col %d -> col %d%s%s  [moves %d, score %d]",
    #moving, #moving > 1 and "s" or "", card.label(moving[1]),
    fromCol, toCol, flipped and " + flipped one" or "",
    setsPhrase(sets), g.moves, g.score))
end

-- ===== 补牌（M4）=====
--
-- 蜘蛛纸牌的补牌规则有两条硬约束，第二条最容易忘：
--   1. stock 里得还有牌（一共 50 张 = 5 轮，每轮 10 张）。
--   2. ⚠ 10 列必须【全部非空】。只要有一列空着，就一轮都不许补。
--      原因是补牌是"每列各加一张"，空列没有牌可压，加上去会破坏牌的连续性；
--      真实规则里的做法就是直接禁止，而不是照顾空列少发一张。
--
-- 补牌算不算一步？算。微软经典规则里补一轮也扣 1 分、记 1 步 ——
-- 否则玩家可以反复补牌而不付代价，分数就失去意义了。
-- （开局那次发牌在 deck.dealNewGame 里完成，不经过这里，所以不扣分。）

-- 返回第一个空列号；全非空返回 nil
function M.firstEmptyColumn(g)
  for i = 1, const.COLS do
    if #g.tableau[i] == 0 then return i end
  end
  return nil
end

-- 还能补几轮（给界面显示用）：50 张 → 5 轮
function M.dealsLeft(g)
  return math.ceil(#g.stock / const.COLS)
end

-- 现在能不能补牌？ok, 不能补的原因
-- 界面用它来决定 stock 是"亮着可点"还是"灰着不可点"
function M.canDealFromStock(g)
  if #g.stock == 0 then
    return false, "stock is empty - no more deals"
  end
  local empty = M.firstEmptyColumn(g)
  if empty then
    return false, string.format("col %d is empty - every column must have a card before dealing", empty)
  end
  return true
end

-- 补一轮：10 列各从 stock 取 1 张，翻开。
-- 返回 ok, 描述。
function M.dealFromStock(g)
  local ok, why = M.canDealFromStock(g)
  if not ok then
    -- 失败【不清选中】：可能只是手上还选着牌，用户换一下动作即可
    return false, say(g, why)
  end

  -- 从 stock 尾部取牌（LIFO，和 deck.dealNewGame 一致，这样同一副牌的取牌顺序可预测）
  -- 注意：先取到的给第 1 列，依次往右。10 次刚好取走一轮。
  M.pushHistory(g)                   -- M7：补牌也是"一步"，同样要能撤销

  for i = 1, const.COLS do
    local c = table.remove(g.stock)
    c.faceUp = true                    -- 补上来的牌一律正面朝上
    g.tableau[i][#g.tableau[i] + 1] = c
  end

  -- 动画（M8）：10 张牌同时从 stock 那个位置飞向各自的列，从左到右依次出发。
  -- dx/dy 是「起始位置 - 最终位置」，render 用它算出起点再滑回 0。
  local groups = {}
  for i = 1, const.COLS do
    local col = g.tableau[i]
    local idx = #col
    groups[#groups + 1] = {
      col   = i,
      first = idx,
      count = 1,
      dx    = const.STOCK_X - const.colX(i),
      dy    = const.STOCK_Y - layout.cardY(col, idx),
      delay = (i - 1) * const.ANIM_STOCK_STAGGER,
    }
  end
  emit(g, { kind = "shift", dur = const.ANIM_STOCK, groups = groups })

  g.moves = g.moves + 1
  g.score = g.score - const.SCORE_PER_MOVE

  -- 补牌把 10 列全改了，"上一步"这个概念不再有意义 —— 清掉，
  -- 否则 hint 还会拿补牌前的移动去判"是不是原路搬回去"。
  g.lastMove = nil

  -- 补牌也可能补齐一组 —— 比如某列已经有 K..2，这次补上一张同花 A。
  local sets = M.collectCompleteSets(g)

  M.deselect(g)

  return true, say(g, string.format("dealt a card to every column (%d deal%s left)%s  [moves %d, score %d]",
    M.dealsLeft(g), M.dealsLeft(g) == 1 and "" or "s",
    setsPhrase(sets), g.moves, g.score))
end

-- ===== 终端用的 ASCII 快照 =====

local SUIT_LETTER = { spades = "S", hearts = "H", diamonds = "D", clubs = "C" }

local function cardText(c)
  return card.rankText(c.rank) .. (SUIT_LETTER[c.suit] or "?")
         .. (c.faceUp and "" or "*")        -- * = 背面
end

-- 把牌局打成人类可读的多行文本（列底在左、列顶在右，* 表示背面）
function M.dump(g)
  local out = {}
  out[#out + 1] = string.rep("-", 68)
  for i = 1, 10 do
    local col = g.tableau[i]
    local parts = {}
    for k = 1, #col do
      parts[#parts + 1] = cardText(col[k])
      if k < #col then parts[#parts + 1] = "|" end
    end
    out[#out + 1] = string.format("  col %2d (%d)  %s", i, #col, table.concat(parts, " "))
  end
  out[#out + 1] = string.format("  stock (%d)   foundations: S%d H%d D%d C%d  = %d/8   moves=%d score=%d undo=%d",
    #g.stock, g.foundations.spades, g.foundations.hearts,
    g.foundations.diamonds, g.foundations.clubs,
    M.foundationTotal(g), g.moves, g.score, M.undoDepth(g))
  out[#out + 1] = string.rep("-", 68)
  return table.concat(out, "\n")
end

return M
