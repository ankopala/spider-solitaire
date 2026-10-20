-- src/rules.lua —— 蜘蛛纸牌的规则判定（M3）
--
-- 【重要】本文件不引用 love，也【不修改任何数据】。
-- 它只回答「这样行不行」，真正搬牌的是 src/game.lua。
-- 所以它能在终端用普通 Lua 直接跑测试（见 tests/rules_smoke.lua）。
--
-- 规则要点（⚠ 是最容易写错的一条）：
--   · 单张放置：可以放到【任意】比它大 1 的牌上，不限花色（红 9 能放黑 10）。
--   · ⚠ 整组移动：只有【同花色 + 连续降序】的序列才能整组移动。
--       混花色序列可以叠放（合法），但叠完之后搬不动，只能逐张拆。
--   · 空列：任意单张或合法同花序列都能放（与 Klondike 不同，不限 K）。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local M = {}

-- 列顶牌（空列返回 nil）
function M.topCard(col)
  return col[#col]
end

-- 判断 tableau[col] 从 index 起到列尾，是否构成「可整组移动」的序列
-- 注意：单张翻开牌【总是】可移动（循环不执行，直接返回 true）
function M.canPickUp(col, index)
  if index < 1 or index > #col then return false end

  if not col[index].faceUp then return false end       -- 背面牌拿不起来

  for i = index, #col - 1 do                            -- 相邻两张逐对检查
    local cur, nxt = col[i], col[i + 1]
    if not nxt.faceUp            then return false end  -- 后面藏着背面牌
    if nxt.suit ~= cur.suit      then return false end  -- ⚠ 必须同花
    if nxt.rank ~= cur.rank - 1  then return false end  -- 必须连续降序（差正好 1）
  end

  return true
end

-- 落点是否合法：把「底牌点数为 movingRank」的这一段放到 dstCol 上
function M.canDrop(dstCol, movingRank)
  if #dstCol == 0 then return true end                  -- 空列：任意牌/序列都能放

  local top = dstCol[#dstCol]
  if not top.faceUp then return false end               -- 顶牌还盖着，接不了
  return top.rank == movingRank + 1                     -- 不限花色，只要大 1
end

-- 从 index 到列尾一共几张（纯粹为打印/显示方便）
function M.sequenceLength(col, index)
  if index < 1 or index > #col then return 0 end
  return #col - index + 1
end

-- ===== 成组判定（M5）=====

-- 一列「凑成一组」的条件：列尾正好 13 张，且是【同一花色】的 K→A 连续降序，
-- 每一张都正面朝上。满足则返回花色字符串，否则返回 nil。
--
-- 注意三点：
--   1. 只看【列尾】13 张。整组上方还可能压着别的牌（那些牌不受影响）；
--   2. 必须同花 —— 混花色的 K..A 虽然能叠在一起，但不算完成，不能收走
--      （这条和 canPickUp 的"同花+降序"是同一个道理，但判定对象不同：
--        一个看能不能搬，一个看能不能收）；
--   3. 必须全部 faceUp。列尾 13 张里有背面牌说明这一组还没真正露出来。
function M.completeSetSuit(col)
  local n = #col
  if n < 13 then return nil end                     -- 连 13 张都没有，不可能成组

  local startIdx = n - 12                           -- 列尾 13 张的第一张（应该是 K）
  local first = col[startIdx]
  if not first.faceUp or first.rank ~= 13 then return nil end

  for i = startIdx, n do
    local c = col[i]
    if not c.faceUp                    then return nil end   -- 藏着背面牌
    if c.suit ~= first.suit            then return nil end   -- 混花色
    if c.rank ~= 13 - (i - startIdx)   then return nil end   -- 不是逐级降 1（应依次 13,12,…,1）
  end

  return first.suit
end

return M
