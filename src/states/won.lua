-- src/states/won.lua —— 胜利结算屏
--
-- M5 时这只是 render.lua 里的一块临时横幅；M6 起它有独立状态：
-- 可以把最后一局的牌桌当背景（压暗），也可以接动画/统计，而不污染 render。
--
-- enter 的入参是 playing 传过来的摘要：
--   { game = 牌局, difficulty = 4, score = 1200, moves = 87 }

local const  = require("const")
local anim   = require("src.anim")
local dev    = require("src.dev")          -- M13：只在 ctx.dev 为真时用到
local game   = require("src.game")
local render = require("src.render")
local seed   = require("src.seed")
local text   = require("src.text")
local ui     = require("src.ui")

local M = {}

function M.new(ctx)
  local s = { ctx = ctx, summary = nil, g = nil, focus = 1, buttons = {}, t = 0 }

  local bw, bh = 240, 56
  local x0, y0 = 390, 424

  s.buttons[1] = ui.button{
    x = x0, y = y0, w = bw, h = bh,
    label = text.play_again,
    primary = true,
    act = function() ctx.sm:set("playing") end,       -- playing:enter 会重新发牌
  }

  s.buttons[2] = ui.button{
    x = x0 + bw + 20, y = y0, w = bw, h = bh,
    label = text.main_menu,
    act = function() ctx.sm:set("menu") end,
  }

  function s:enter(summary)
    self.summary = summary or {}
    self.g       = self.summary.game
    self.focus   = 1
    self.t       = 0                     -- 入场动画的时钟（M8）
    print(string.format("[state] won (score=%s, moves=%s)",
      tostring(self.summary.score), tostring(self.summary.moves)))
  end

  -- 入场动画：面板先出来，标题、战绩、按钮依次跟上。
  -- 全部用 alpha 做，不改位置 —— 底下的按钮是绝对坐标，跟着位移会对不齐。
  function s:update(dt)
    self.t = (self.t or 0) + dt
  end

  -- 离开时松掉对牌局的引用：它已经没用了，别让旧牌局跟着状态对象一直占内存
  function s:leave()
    self.summary = nil
    self.g = nil
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
    -- ===== DEV（M13）：连按 J 把统计行切成下一档假数据 =====
    -- 档位存在 ctx.devVariant 上，所以从 playing 跳过来之后还能接着切。
    -- 只改显示用的五个字段，game / score / moves / difficulty 原样不动 ——
    -- 背景牌桌和 seed 行必须保持真实，否则调出来的就不是玩家看到的排版。
    if self.ctx.dev and key == "j" then
      local i = dev.next(self.ctx)
      local v = dev.variant(self.ctx)
      local sum = self.summary
      sum.best, sum.wins, sum.games, sum.pct, sum.isNewBest =
        v.best, v.wins, v.games, v.pct, v.isNewBest
      print(string.format("[dev] won stats -> #%d %s", i, v.name))
      return
    end

    if key == "return" or key == "kpenter" or key == "space" or key == "r" then
      self:activate(1)
    elseif key == "escape" or key == "m" then
      self:activate(2)
    elseif key == "left" or key == "a" then
      self.focus = 1
    elseif key == "right" or key == "d" then
      self.focus = 2
    end
  end

  function s:draw(u)
    local mx, my = u and u.mouseX, u and u.mouseY
    local t = self.t or 0

    -- 每一段用「延迟 + 时长」做阶梯淡入
    local function stage(delay, dur)
      return anim.easeOutCubic(anim.clamp01((t - delay) / dur))
    end

    if self.g then
      render.draw(self.g, u)        -- 最后一局的牌桌当背景
    end

    local back = stage(0, 0.30)
    ui.dim(const.HUD_H, 0.78 * back)             -- 顶栏留着，分数在 HUD 上也看得见

    local pw, ph = 600, 340
    local px, py = (const.VW - pw) / 2, 190
    ui.panel(px, py, pw, ph, back)

    -- 描边缓慢呼吸：让这一屏"活着"，而不是一张静止的截图。
    -- 只叠在描边上，不动底色，所以不会把文字衬得忽明忽暗。
    local pulse = 0.20 + 0.30 * (0.5 + 0.5 * math.sin(t * 2.2))
    if back > 0 then ui.panelBorder(px, py, pw, ph, back * pulse) end

    ui.center(text.won_title, "big", py + 34, const.COLOR_TEXT, stage(0.10, 0.28))

    local sets = self.g and game.foundationTotal(self.g) or const.FOUND_COUNT
    local k2   = stage(0.22, 0.28)
    ui.center(string.format(text.won_runs, sets, const.FOUND_COUNT),
      "tiny", py + 116, const.COLOR_TEXT_DIM, k2)
    ui.center(string.format(text.won_stats, self.summary.score or 0, self.summary.moves or 0),
      "small", py + 150, const.COLOR_TEXT, k2)

    -- 统计行：最高分 + 胜率合成一行。
    -- 拆两行会压到按钮上（py+184 之后到 424 只剩 48px），所以只能挤一行。
    local line = text.stats(
      self.summary.best or 0,
      self.summary.wins or 0,
      self.summary.games or 0,
      self.summary.pct,
      self.summary.isNewBest)

    if line then
      ui.center(line, "tiny", py + 184,
        self.summary.isNewBest and const.COLOR_TEXT or const.COLOR_TEXT_DIM, k2)
    end

    -- 这一局的种子：想重玩或分享给朋友，靠这一行抄下来
    if self.g and self.g.seed then
      ui.center(string.format(text.won_seed,
        seed.format(self.g.seed),
        text.suitCount(self.summary.difficulty or 4)),
        "tiny", py + 206, const.COLOR_TEXT_DIM, k2)
    end

    local k3 = stage(0.36, 0.28)
    for i, b in ipairs(self.buttons) do
      ui.drawButton(b, ui.hit(b, mx, my), i == self.focus, k3)
    end

    ui.center(text.nav_hint, "tiny", py + ph - 34, const.COLOR_TEXT_DIM, stage(0.48, 0.28))
  end

  return s
end

return M
