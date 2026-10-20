-- src/ui.lua —— 菜单/按钮这类"界面零件"的绘制与命中检测
--
-- 只有这里和 states/* 会碰 love.graphics；牌桌仍然完全交给 src/render.lua。
-- 【重要】本文件在 require 阶段不调用任何 love.* —— 这样 states 模块能在终端被加载，
-- 从而用普通 Lua 测试键盘/鼠标逻辑（见 tests/states_smoke.lua）。
--
-- 视觉语言仍然守着黑白灰：
--   普通    深灰底 + 中灰描边 + 浅灰字
--   悬停    浅灰底 + 深灰字（反色，最醒目）
--   选中    中灰底 + 亮描边（用于"当前难度"这类持久状态）
--
-- M8：颜色不再写在这里，统一从 const 取 —— 之前牌桌和界面各有一套灰阶，
-- 改一次配色要改两处，两边还慢慢漂开了。

local const  = require("const")
local render = require("src.render")

local M = {}

local COLOR = {
  fill       = const.COLOR_BTN_FILL,
  fillHot    = const.COLOR_BTN_FILL_HOT,
  fillActive = const.COLOR_BTN_FILL_ACTIVE,
  line       = const.COLOR_BTN_LINE,
  lineHot    = const.COLOR_BTN_LINE_HOT,
  lineActive = const.COLOR_BTN_LINE_ACTIVE,
  text       = const.COLOR_TEXT,
  textHot    = const.COLOR_TEXT_HOT,
  textActive = const.COLOR_TEXT_ACTIVE,
}

local function setColor(c, a)
  love.graphics.setColor(c[1], c[2], c[3], a or 1)
end

-- 按钮构造。kind = "action"（居中一行）| "option"（左对齐 + 说明文字）
function M.button(t)
  return {
    x       = t.x,
    y       = t.y,
    w       = t.w or 320,
    h       = t.h or 56,
    label   = t.label or "",
    sub     = t.sub,
    act     = t.act,
    kind    = t.kind or "action",
    primary = t.primary or false,
  }
end

-- 鼠标是否在按钮矩形内（纯数学，不碰 love）
function M.hit(b, mx, my)
  if not mx or not my then return false end
  return mx >= b.x and mx <= b.x + b.w and my >= b.y and my <= b.y + b.h
end

function M.drawButton(b, hot, active, alpha, checked)
  alpha = alpha or 1
  if checked == nil then checked = active end     -- 不传就退回老行为：高亮即"当前值"
  local fill, line, txt

  if hot then
    fill, line, txt = COLOR.fillHot, COLOR.lineHot, COLOR.textHot
  elseif active then
    fill, line, txt = COLOR.fillActive, COLOR.lineActive, COLOR.textActive
  else
    fill, line, txt = COLOR.fill, COLOR.line, COLOR.text
  end

  -- primary（主按钮）在非悬停时也把描边提亮，视线先落上去
  if not hot and b.primary then line = COLOR.lineActive end

  local r = 8
  setColor(fill, alpha)
  love.graphics.rectangle("fill", b.x, b.y, b.w, b.h, r, r)
  setColor(line, alpha)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", b.x, b.y, b.w, b.h, r, r)
  love.graphics.setLineWidth(1)

  if b.kind == "option" then
    local f  = render.font("small")
    local ft = render.font("tiny")

    -- 两行文字整体在按钮里垂直居中，行间距直接用字体的实际行高。
    -- 【坑】不要写死 "+7 / +33" 这种偏移：按钮高度一改（M9 从 78 压到 56/64），
    -- 说明文字就会压到边框上甚至被右侧的"当前值"方块盖住。
    local total = f:getHeight() + (b.sub and ft:getHeight() or 0)
    local ty    = b.y + math.floor((b.h - total) / 2)

    setColor(txt, alpha)
    love.graphics.setFont(f)
    love.graphics.print(b.label, b.x + 24, ty)

    if b.sub then
      -- 悬停时底色变亮、文字变深，说明文字也要跟着加深，否则会发灰看不清
      setColor(txt, (hot and 0.75 or 0.68) * alpha)
      love.graphics.setFont(ft)
      love.graphics.print(b.sub, b.x + 24, ty + f:getHeight())
    end

    -- 当前值：右侧一个实心小方块（比文字"current"更省地方，也不引入新色相）。
    -- 注意用 checked 而不是 active 判断：键盘焦点移到别的选项时，
    -- 不能把"焦点"和"当前值"都画成方块，否则一眼看不出到底选了哪个。
    if checked then
      setColor(txt, alpha)
      love.graphics.rectangle("fill", b.x + b.w - 36, b.y + b.h / 2 - 6, 12, 12, 3, 3)
    end
  else
    local f = render.font("small")
    local tw = f:getWidth(b.label)
    local th = f:getHeight()
    setColor(txt, alpha)
    love.graphics.setFont(f)
    love.graphics.print(b.label, b.x + (b.w - tw) / 2, b.y + (b.h - th) / 2)
  end

  setColor(COLOR.text)          -- 复位，别让半透明/深色渗到后面的绘制
end

-- 面板（胜利结算、设置底板这类）
function M.panel(x, y, w, h, alpha)
  setColor(const.COLOR_PANEL, alpha)
  love.graphics.rectangle("fill", x, y, w, h, 12, 12)
  setColor(COLOR.line, alpha)
  love.graphics.rectangle("line", x, y, w, h, 12, 12)
  setColor(COLOR.text)
end

-- 只画面板描边（不画底）：用来做"呼吸"高亮，叠在 panel 之上
function M.panelBorder(x, y, w, h, alpha)
  setColor(COLOR.lineActive, alpha)
  love.graphics.setLineWidth(2)
  love.graphics.rectangle("line", x, y, w, h, 12, 12)
  love.graphics.setLineWidth(1)
  setColor(COLOR.text)
end

-- 整屏压暗（胜利时盖在牌桌上）。top 默认 0；传 HUD_H 可以保留顶栏可读。
function M.dim(top, alpha)
  top = top or 0
  setColor(const.COLOR_BG, alpha or 0.78)
  love.graphics.rectangle("fill", 0, top, const.VW, const.VH - top)
  setColor(COLOR.text)
end

-- 水平居中打印（菜单标题、结算文字之类）
function M.center(s, fontName, y, color, alpha)
  local f = render.font(fontName)
  local w = f:getWidth(s)
  love.graphics.setFont(f)
  if color then setColor(color, alpha) end
  love.graphics.print(s, (const.VW - w) / 2, y)
end

-- 左对齐打印（设置屏的小节标题用）
function M.left(s, fontName, x, y, color, alpha)
  local f = render.font(fontName)
  love.graphics.setFont(f)
  if color then setColor(color, alpha) end
  love.graphics.print(s, x, y)
end

return M
