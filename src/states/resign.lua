-- src/states/resign.lua —— 认输确认面板（M10）
--
-- 为什么单独开一个状态，而不是在 playing 里画个浮层？
--   浮层要自己处理"点外面的区域要不要穿透到牌桌"，还得记住原来选中的是哪张牌；
--   而状态机切一下就把输入全接过去了，回来时 playing 原样还在。
--   代价只是多一个文件，划算。
--
-- enter 的入参：{ game = 当前牌局 }
--   面板上的三个出口：
--     Restart this deal  game.restart(g)  → 同一副牌、同样的发牌顺序重开
--     New deal           直接切回 playing（playing:enter 会重新发牌）
--     Keep playing       切回 playing 并保留牌局

local const   = require("const")
local game    = require("src.game")
local persist = require("src.persist")
local render  = require("src.render")
local seed    = require("src.seed")
local text    = require("src.text")
local ui      = require("src.ui")

local M = {}

function M.new(ctx)
  local s = {
    ctx     = ctx,
    g       = nil,
    focus   = 1,
    buttons = {},
    t       = 0,
  }

  -- ===== 版式 =====
  local pw, ph = 660, 372
  local px, py = (const.VW - pw) / 2, (const.VH - ph) / 2 - 6

  local bw, bh = 540, 62
  local bx     = px + (pw - bw) / 2
  local by0    = py + 128
  local gap    = 8

  -- ⚠ 三个按钮都用具名下标：以后再加一项不会让键盘/测试里的数字全部错位
  s.idxRestart = #s.buttons + 1
  s.buttons[s.idxRestart] = ui.button{
    x = bx, y = by0, w = bw, h = bh, kind = "option",
    label = text.resign_restart.name,
    sub   = text.resign_restart.sub,
    primary = true,
    act = function()
      -- 就地重置：s.g 和 playing.g 是同一个 table，所以不用来回传引用。
      -- ⚠ 闭包里用 s 而不是 self —— 按钮是普通函数，调用时没有 self。
      game.restart(s.g)
      ctx.sm:set("playing", { resume = true })
    end,
  }

  s.idxNew = #s.buttons + 1
  s.buttons[s.idxNew] = ui.button{
    x = bx, y = by0 + (bh + gap), w = bw, h = bh, kind = "option",
    label = text.resign_new.name,
    sub   = text.resign_new.sub,
    act = function()
      -- 认输算输：这是"这一局有结论"的唯一失败出口。
      -- Restart this deal（同一副牌重来）与 Keep playing 都不计 —— 用户定的口径。
      -- ⚠ 必须写在这里（点击当下），不能写进 leave：三个出口都会触发 leave。
      if s.g and not game.isWon(s.g) then
        persist.recordResult(s.ctx.settings, s.g.difficulty, false)
        if s.ctx.saveSettings then s.ctx.saveSettings() end
      end

      -- 不带 resume → playing:enter 用新种子发一副牌
      ctx.sm:set("playing")
    end,
  }

  s.idxCancel = #s.buttons + 1
  s.buttons[s.idxCancel] = ui.button{
    x = bx, y = by0 + (bh + gap) * 2, w = bw, h = bh, kind = "option",
    label = text.resign_cancel.name,
    sub   = text.resign_cancel.sub,
    act = function()
      ctx.sm:set("playing", { resume = true })
    end,
  }

  function s:enter(summary)
    self.g     = summary and summary.game or nil
    self.focus = 1
    self.t     = 0
    print("[state] resign")
  end

  -- 只用于面板的轻微淡入，别的不做
  function s:update(dt)
    self.t = self.t + dt
  end

  function s:leave()
    self.g = nil                    -- 松开引用，别让旧牌局跟着状态对象一直挂着
  end

  function s:activate(i)
    self.focus = i
    self.buttons[i].act()
  end

  function s:mousepressed(mx, my, button)
    if button ~= 1 then return end
    for i, b in ipairs(self.buttons) do
      if ui.hit(b, mx, my) then
        self:activate(i)
        return
      end
    end
  end

  function s:keypressed(key)
    local n = #self.buttons
    if key == "up" or key == "w" then
      self.focus = (self.focus - 2) % n + 1
    elseif key == "down" or key == "s" then
      self.focus = (self.focus % n) + 1
    elseif key == "return" or key == "kpenter" or key == "space" then
      self:activate(self.focus)
    elseif key == "1" then
      self:activate(self.idxRestart)
    elseif key == "2" then
      self:activate(self.idxNew)
    elseif key == "3" or key == "escape" then
      -- Esc = 反悔。这个面板是"确认破坏性操作"，默认出口必须是无害的那个。
      self:activate(self.idxCancel)
    end
  end

  function s:draw(u)
    local mx, my = u and u.mouseX, u and u.mouseY

    if self.g then
      render.draw(self.g, u)         -- 牌桌当背景：让玩家看清自己是在放弃什么
    end

    -- 面板淡入（0.18s）。用 alpha 不用位移：按钮是绝对坐标，跟着动会对不齐。
    local k = math.min(1, (self.t or 0) / 0.18)

    ui.dim(const.HUD_H, 0.82 * k)

    local pw, ph = 660, 372
    local px, py = (const.VW - pw) / 2, (const.VH - ph) / 2 - 6
    ui.panel(px, py, pw, ph, k)

    ui.center(text.resign_title, "big",   py + 26, const.COLOR_TEXT,     k)

    -- 说明里带上种子：玩家想在放弃前把这局记下来，还有机会（抄走就能重玩）
    local lede = text.resign_lede
    if self.g and self.g.seed then
      lede = string.format(text.resign_lede_seed, seed.format(self.g.seed))
    end
    ui.center(lede, "tiny", py + 96, const.COLOR_TEXT_DIM, k)

    for i, b in ipairs(self.buttons) do
      -- 第 5 个参数 checked 显式传 false：这些是"动作"不是"选项"，
      -- 不传的话 drawButton 会退回"焦点即当前值"的老行为，在焦点按钮右侧画一个方块 ——
      -- 看着像"这一项已经选中了"，其实这里根本没有"当前值"这回事。
      ui.drawButton(b, ui.hit(b, mx, my), i == self.focus, k, false)
    end

    ui.center(text.nav_hint, "tiny", py + ph - 26, const.COLOR_TEXT_DIM, k)
  end

  return s
end

return M
