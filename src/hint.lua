-- src/hint.lua —— 「下一步该走哪」的判定（纯逻辑）
--
-- 【重要】本文件不引用 love，也【不修改 g】—— 所以能在终端跑测试（tests/hint_smoke.lua）。
--
-- 判定方式就是穷举，但有两个刻意的选择：
--
-- ① 不自己再写一遍「从列尾回溯同花降序尾巴」的算法，而是直接调 rules.canPickUp 逐 index 试。
--    10 列 × 13 张 × 10 个落点 ≈ 1700 次调用，一次操作算一次，微秒级；
--    换来的是「提示」和「真正搬牌」共用一份规则 —— 不会出现"提示说能走、实际走不了"。
--
-- ② 【不是找到第一个就返回，而是全部扫完挑最好的】。
--    这一点是 2026-10-19 补的，原版"找到就返回"有个很烦的副作用：
--    扫描顺序固定（列 1→10、index 1→…、目标 1→10），于是它会机械地给出
--    「A 列 → B 列」，玩家照做之后，下一次又从 B 列开始扫、又给出「B 列 → A 列」。
--    实测 60 局全部出现这种往返循环（69 次连续两步互为逆操作）。
--    牌并没有真的无路可走 —— 只是提示在指着一手毫无意义的手。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local const = require("const")
local game  = require("src.game")     -- 只为复用 canDealFromStock；game 不反向依赖本文件
local rules = require("src.rules")

local M = {}

-- ===== 候选打分 =====
--
-- 分数只用来【排序】，不参与"有没有路"的判定 —— 这一点很重要：
-- 就算所有候选都是 0 分，局面依然是"有牌可动"，不能谎报死局。
--
-- 蜘蛛纸牌里唯一会产出【新信息】的动作就是「翻开一张背面牌」：
-- 别的动作都只是在已知的牌之间挪来挪去。所以它一项就占了 100 分，
-- 其余几项只是用来打破平局、让提示看起来"像个会玩的人在指路"。
local function scoreOf(g, move)
  local src  = g.tableau[move.from]
  local dst  = g.tableau[move.to]
  local card = src[move.index]
  local s    = 0

  -- ① 搬走之后，原列的新顶牌是背面 → 会翻开一张新牌（真进展）
  if move.index > 1 and not src[move.index - 1].faceUp then
    s = s + 100
  end

  -- ② 落到同花牌上 → 正在朝"凑成一组"的方向走
  local top = dst[#dst]
  if top and top.suit == card.suit then
    s = s + 60
  end

  -- ③ 把整列搬走 → 腾出一个空列。
  --    ⚠ 只在 stock 已空时才算好事：game.canDealFromStock 要求【10 列全非空】，
  --    所以库存还有牌的时候清空一列，等于自己把补牌的路堵死了 —— 那不是进展。
  if move.index == 1 and #g.stock == 0 then
    s = s + 25
  end

  -- ④ 落到空列 → 能当临时缓冲区，但比不上同花接续
  if #dst == 0 then
    s = s + 10
  end

  return s
end

-- 排序规则：分数降序；同分按 (from, index, to) 升序。
--
-- 【为什么这构成了严格全序】
--   扫描顺序是 c → i → d，而 (from, index, to) 的三元组在扫描中唯一，
--   所以任意两个候选都不会"完全相等"，比较器不会出现平局。
--   这意味着 table.sort 的不稳定性对结果没有任何影响 —— 排序结果唯一。
--   同时它也就是老 findMove 的"同分留先扫到的"语义（先扫到的 = 三元组最小的）。
--
-- ⚠ 不能用 a.score <= b.score：Lua 会抛 invalid order function。
local function byRank(a, b)
  if a.score ~= b.score then return a.score > b.score end
  if a.from  ~= b.from  then return a.from  < b.from  end
  if a.index ~= b.index then return a.index < b.index end
  return a.to < b.to
end

-- 一次扫描，两种产物：
--   collect=false → 只返回择优的那一手（findMove / F1 浮层用，零分配）
--   collect=true  → 返回全部候选，排好序（连按 H 循环用）
--
-- ⚠ 保留"严格大于"：同分时留先扫到的那个。改成 >= 会让 findMove 的答案
--   变成"同分里最后扫到的"，hint_smoke 有 7 条断言直接锁着具体是哪一手。
local function scan(g, collect)
  -- 上一步走的是哪两列。只用来给"原路搬回去"扣分，不禁止 ——
  -- 真要说只有这一步能走时，它仍然是答案（宁可给个笨答案，也不谎报无路）。
  local avoid = g.lastMove

  local best, bestScore = nil, nil
  local list = collect and {} or nil

  for c = 1, const.COLS do
    local src = g.tableau[c]

    for i = 1, #src do
      if rules.canPickUp(src, i) then          -- 单张正面牌恒为 true
        local rank = src[i].rank

        for d = 1, const.COLS do
          if d ~= c then
            local dst = g.tableau[d]

            local legal
            if #dst == 0 then
              legal = (i > 1)                  -- 整列搬到空列 = 原地换位，不算
            else
              legal = rules.canDrop(dst, rank)
            end

            if legal then
              local move = {
                from  = c,
                index = i,
                to    = d,
                count = #src - i + 1,
                -- 这一手会不会翻开一张背面牌。蜘蛛纸牌里这是【唯一】产出新信息的动作，
                -- 所以它同时决定了 hint 的排序，以及"是不是只剩无意义的挪动"。
                flips = (i > 1 and not src[i - 1].faceUp) or false,
              }
              local s = scoreOf(g, move)

              -- 上一步刚把这叠牌从 d 搬到 c，现在又想搬回去 → 纯粹往返。
              -- -500 保证它排在所有候选最后；但真没别的可走时还是会被选中。
              if avoid and avoid.from == move.to and avoid.to == move.from then
                s = s - 500
              end

              move.score = s
              if collect then list[#list + 1] = move end
              if not best or s > bestScore then     -- 同分保留先找到的（确定性）
                best, bestScore = move, s
              end
            end
          end
        end
      end
    end
  end

  if not collect then return best end

  table.sort(list, byRank)
  return list
end

-- 找一手能走的牌。找到就返回 { from, index, to, count, score }，否则 nil。
--
-- ⚠ 空列必须单独处理。rules.canDrop 对空列恒为 true，照直写的话
--   【只要场上有一个空列，就永远"有路"】—— 而收组之后经常会出现空列，
--   于是这个判定永远不会报"无路可走"，整个功能等于废掉。
--
--   但「把一整列原封不动搬到空列」只是原地换个位置，不产生任何新机会，
--   所以排除 index == 1。index > 1 时留在原列的牌至少可能是一张还没翻开的
--   背面牌 —— 那才是真正的机会。
function M.findMove(g)
  return scan(g, false)
end

-- 同一牌桌上的【全部】合法走法，按分数从高到低。
--
-- 列表包含所有候选，包括"翻不开牌、只是把牌挪个位置"的废手，
-- 以及 -500 的"上一步的逆操作"（它只是沉到末尾，不会被过滤）。
-- 这是刻意的：提示只负责排序，不替玩家过滤选项。
--
-- 返回的永远是 table（没有走法时是空表，不是 nil），
-- 这样调用方可以无条件写 #list。
function M.findMoves(g)
  return scan(g, true)
end

-- 四档状态，返回 status, move（move 只有 "moves" / "stall" 时非 nil）：
--   "moves"  还有牌可动，而且其中有能翻开新牌的
--   "stall"  还有牌可动，但没有一手能翻开新牌，也补不了牌
--            —— 这才是玩家说的"提示让我 A→B 再 B→A"的真正处境：
--               牌没死，只是在正面牌之间来回挪，永远翻不出新东西。
--               措辞上刻意说"翻不出新牌"而不是"死局"：这需要搜索才能断言，
--               静态判定说不准（挪几步之后某列可能就露出背面牌了）。
--   "deal"   没牌可动，但可以补牌 —— 补牌本身是合法动作，不该说人家死了
--   "stuck"  既没牌可动，也补不了牌
-- list 可选：由 M.findMoves(g) 得到、且必须来自同一个 g。
-- 传了就不重复扫描（requestHint 已经拿到整张表了）。
--
-- ⚠ 不能写成 `local move = list and list[1] or M.findMove(g)`：
--   空表时 list[1] 是 nil，会静默回退成再扫一遍。
--   那不只是白扫一次 —— 如果两次扫描之间 g 被动过，两个答案会不一致。
function M.status(g, list)
  local move
  if list then
    move = list[1]
  else
    move = M.findMove(g)
  end

  if move then
    if move.flips then return "moves", move end

    -- 不能翻牌，但还能补牌 → 补牌本身会翻开 10 张新牌，别急着吓人
    if game.canDealFromStock(g) then return "moves", move end

    return "stall", move
  end

  if game.canDealFromStock(g) then return "deal", nil end

  return "stuck", nil
end

return M
