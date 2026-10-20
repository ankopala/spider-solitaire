-- src/layout.lua —— 牌桌几何：叠压位置计算 + 鼠标命中检测（M3）
--
-- 为什么单独拆一个文件？
--   因为「牌画在哪里」和「点击打中了哪张牌」必须用同一套算法。
--   如果 render 算一套 y、mousepressed 又算一套，改布局时两边就会不一致 →
--   出现「明明点在这张牌上却选了另一张」这种最难查的 bug。
--   所以两边都从这里取坐标。
--
-- 【重要】本文件只用 const 里的数字，不引用 love，因此可在终端跑测试。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local const = require("const")

local M = {}

-- 一张牌后面接着画的下一张牌，要往下挪多少像素
-- 背面牌步长小（只露一条边）；翻开牌步长大（能看清 rank/suit）
function M.stackStep(c)
  return c.faceUp and const.STEP_UP or const.STEP_DOWN
end

-- 列内第 index 张牌（第 1 张在最上）的 y 坐标
function M.cardY(col, index)
  local y = const.TABLEAU_Y
  for i = 1, index - 1 do
    y = y + M.stackStep(col[i])
  end
  return y
end

-- 第 index 张牌「露出来」的高度：
-- 非最后一张只露一个步长，最后一张是整张牌高
function M.visibleH(col, index)
  if index == #col then return const.CARD_H end
  return M.stackStep(col[index])
end

local function pointInRect(px, py, x, y, w, h)
  return px >= x and px <= x + w and py >= y and py <= y + h
end

-- 鼠标（虚拟坐标）是否落在某张 tableau 牌上？
-- 返回 col, index；没打中返回 nil
-- 从列尾往前找：越靠后的牌画得越上面，应该优先命中
function M.hitTestTableau(g, vx, vy)
  for i = 1, const.COLS do
    local col = g.tableau[i]
    local x = const.colX(i)
    if vx >= x and vx <= x + const.CARD_W then
      for k = #col, 1, -1 do
        local y = M.cardY(col, k)
        if pointInRect(vx, vy, x, y, const.CARD_W, M.visibleH(col, k)) then
          return i, k
        end
      end
    end
  end
  return nil
end

-- 鼠标是否落在某一列的「空槽」区域（列顶那块牌位）？返回列号或 nil
-- 用途：空列没有牌可点，但仍然要能被点中当作落点
function M.columnSlotAt(vx, vy)
  for i = 1, const.COLS do
    local x = const.colX(i)
    if pointInRect(vx, vy, x, const.TABLEAU_Y, const.CARD_W, const.CARD_H) then
      return i
    end
  end
  return nil
end

-- ===== 落点带（drop band）=====
--
-- 这是 M3 修掉的一个真 bug：老版本只有「牌身」和「列顶空槽」两处能当落点，
-- 点在列里【牌下方】的那一大片空白会被判成"点空"→ 取消选中，
-- 用户看到的现象就是"我点了落点，什么都没发生"。
-- 现在整列从牌顶到底部都算可落区，左右还各外扩半个列间距（点在列缝里也能归位）。

function M.columnBandAt(vx, vy)
  if vy < const.BAND_TOP or vy > const.BAND_BOTTOM then return nil end

  for i = 1, const.COLS do
    local x = const.colX(i) - const.BAND_PAD_X
    if vx >= x and vx <= x + const.CARD_W + const.BAND_PAD_X * 2 then
      return i
    end
  end
  return nil
end

-- 鼠标是否落在 stock（牌库）上？M4 补牌会用到
function M.hitTestStock(vx, vy)
  return pointInRect(vx, vy, const.STOCK_X, const.STOCK_Y, const.STOCK_W, const.STOCK_H)
end

-- 鼠标是否落在撤销按钮上？M7 用。
-- 和牌桌一样：画在哪里（render.drawUndoButton）和点哪里（这里）必须共用同一组常量，
-- 否则改一次布局就会出现"按钮看着在这、点着都不灵"。
function M.hitTestUndo(vx, vy)
  return pointInRect(vx, vy, const.UNDO_X, const.UNDO_Y, const.UNDO_W, const.UNDO_H)
end

-- 鼠标是否落在提示按钮上？（只在 button 模式下才画，但命中检测恒定存在）
-- 同样是「画在哪、点在哪」共用一组常量。
function M.hitTestHint(vx, vy)
  return pointInRect(vx, vy, const.HINT_X, const.HINT_Y, const.HINT_W, const.HINT_H)
end

-- 鼠标是否落在 HUD 里的认输按钮上？（M10）
function M.hitTestResign(vx, vy)
  return pointInRect(vx, vy, const.RESIGN_X, const.RESIGN_Y, const.RESIGN_W, const.RESIGN_H)
end

return M
