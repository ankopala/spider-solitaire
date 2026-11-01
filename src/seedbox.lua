-- src/seedbox.lua —— 「种子方框 + Copy 按钮」控件（M19）
--
-- 为什么抽成控件：Esc 离开面板、认输面板、通关结算屏三处都要显示种子，
-- 也都要"点一下抄走"。三份手抄的矩形计算，改一处漏两处就是"按钮能看见但点不中"。
--
-- 为什么复制要走 ctx.setClipboard 注入：
--   states/* 的铁律是【只在 draw() 里碰 love】—— 而复制发生在 mousepressed。
--   和 ctx.quit / ctx.makeSeed 一样，把 love.system 包成闭包从 main.lua 注进来，
--   states 与这个控件都只认 ctx，终端测试才能塞假函数数次数。
--   （顺便：写不进去时绝不显示 "Copied"，不假报成功。）
--
-- 为什么尺寸是常量：mousepressed 要判定按钮矩形，那一刻不能量字体宽度。
--   宽度依据写在 const.lua 的「种子复制控件」节里，靠探针截图目测兜底。
--
-- 本文件在 require 阶段不碰 love（和 src/ui.lua 同族），所以 states 能在终端被加载。

local const  = require("const")
local render = require("src.render")
local seed   = require("src.seed")
local text   = require("src.text")

local M = {}

local function setColor(c, a)
  love.graphics.setColor(c[1], c[2], c[3], a or 1)
end

-- opt.cx     整组要以哪个 x 为中心（传面板中心）
-- opt.y      顶端
-- opt.chipW  方框宽度（结算屏那行字更长，传 SEEDBOX_CHIP_W_LONG）
function M.new(opt)
  local box = {
    h       = opt.h or const.SEEDBOX_H,
    chipW   = opt.chipW or const.SEEDBOX_CHIP_W,
    btnW    = opt.btnW or const.SEEDBOX_BTN_W,
    y       = opt.y,
    copiedT = 0,
  }
  box.w     = box.chipW + const.SEEDBOX_GAP + box.btnW
  box.x     = opt.cx - box.w / 2
  box.chipX = box.x
  box.btnX  = box.x + box.chipW + const.SEEDBOX_GAP

  return setmetatable(box, { __index = M })
end

-- 面板上那行【显示文字】。没有牌局 / 没有种子 / 种子非法 → nil，控件据此不画也不可点。
-- diffText 只有结算屏会传（"4 suits"）：一局的身份是 (seed, difficulty)，
-- 少一半就变成"同一个种子怎么不是同一局"。
function M.text(g, diffText)
  if not (g and g.seed) then return nil end
  local s = seed.format(g.seed)
  if not s then return nil end
  if not diffText then return string.format(text.seed_chip, s) end
  return string.format(text.won_seed, s, diffText)      -- "seed 1234567890  (4 suits)"
end

-- 复制进剪贴板的内容：**只有那 DIGITS 位数字**。
-- ⚠ 不能把上面那行显示文字直接写进去：多出来的 "seed " 前缀和 " (4 suits)"
--   粘到「Play a seed」屏里会被 paste 当成非数字剥掉 —— 那是运气好；
--   要是哪天改成"原样接受"，就变成粘进去必然非法。要复制就复制值本身。
function M.value(g)
  if not (g and g.seed) then return nil end
  return seed.format(g.seed)
end

-- 命中只算【复制按钮】：方框是"这段值"，按钮才是"动作"。
-- 方框也做成热区的话，玩家在面板上随便点一下就把剪贴板冲掉了。
function M:contains(mx, my)
  if not mx or not my then return false end
  return mx >= self.btnX and mx <= self.btnX + self.btnW
     and my >= self.y    and my <= self.y + self.h
end

function M:copy(value, ctx)
  if not value then return false end
  if not (ctx and ctx.setClipboard) then return false end
  ctx.setClipboard(value)
  self.copiedT = const.SEEDBOX_HOLD
  return true
end

-- states 只调这一个：命中 + 复制。返回 true 表示这次点击被吃掉了。
-- 传的是 value（纯数字），不是 draw 用的那行文字。
function M:click(mx, my, value, ctx)
  if not self:contains(mx, my) then return false end
  return self:copy(value, ctx)
end

function M:update(dt)
  if self.copiedT > 0 then
    self.copiedT = self.copiedT - (dt or 0)
    if self.copiedT < 0 then self.copiedT = 0 end
  end
end

-- 面板每次打开都复位：上次那句 "Copied" 不该跟着新面板一起出来
function M:reset()
  self.copiedT = 0
end

function M:draw(line, alpha, mx, my)
  if not line then return end
  alpha = alpha or 1

  local f  = render.font("tiny")
  local th = f:getHeight()
  local ty = self.y + math.floor((self.h - th) / 2)
  local hot   = self:contains(mx, my)
  local wrote = self.copiedT > 0

  love.graphics.setFont(f)

  -- 方框：填 COLOR_BG 而不是面板色 —— 面板底是 0.18，用同一档就"看不出这里有个框"。
  -- 0.13 比面板暗，读作【内凹字段】，正是"这段值可以拿走"的暗示。
  setColor(const.COLOR_BG, alpha)
  love.graphics.rectangle("fill", self.chipX, self.y, self.chipW, self.h, 7, 7)
  setColor(const.COLOR_BTN_LINE, alpha)
  love.graphics.setLineWidth(1)
  love.graphics.rectangle("line", self.chipX, self.y, self.chipW, self.h, 7, 7)

  setColor(const.COLOR_TEXT, alpha)
  local tw = f:getWidth(line)
  love.graphics.print(line, self.chipX + (self.chipW - tw) / 2, ty)

  -- 按钮：常态照抄 HUD 右上角的 Resign（无填充 + 细边 + 灰字），
  -- 悬停反色 —— 和全项目的按钮语言一致，不引入新样式。
  local cap = wrote and text.copy_done or text.copy
  local ctw = f:getWidth(cap)
  local cx  = self.btnX + (self.btnW - ctw) / 2

  if hot then
    setColor(const.COLOR_SELECT, alpha)
    love.graphics.rectangle("fill", self.btnX, self.y, self.btnW, self.h, 7, 7)
    setColor(const.COLOR_BG, alpha)          -- 浅底上用深字
  elseif wrote then
    setColor(const.COLOR_TEXT_ACTIVE, alpha) -- 刚复制过：描边提亮，1.2s 后自己退回灰
    love.graphics.rectangle("line", self.btnX, self.y, self.btnW, self.h, 7, 7)
    setColor(const.COLOR_TEXT_ACTIVE, alpha)
  else
    setColor(const.COLOR_BTN_LINE, alpha)
    love.graphics.rectangle("line", self.btnX, self.y, self.btnW, self.h, 7, 7)
    setColor(const.COLOR_TEXT_DIM, alpha)
  end

  love.graphics.print(cap, cx, ty)

  setColor(const.COLOR_TEXT, 1)             -- 复位：别让深色/半透明渗到后面的绘制
end

return M
