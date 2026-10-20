-- src/states/menu.lua —— 主菜单
--
-- 只做一件事：把玩家送到 settings（选难度）或者退出。
-- 键盘：↑↓ 移动焦点、Enter/空格 确认；鼠标：点谁算谁。

local const   = require("const")
local persist = require("src.persist")
local seed    = require("src.seed")
local text    = require("src.text")
local ui      = require("src.ui")

local M = {}

function M.new(ctx)
  local s = { ctx = ctx, focus = 1, buttons = {} }

  local bw, bh = 340, 60
  local x = (const.VW - bw) / 2

  s.buttons[1] = ui.button{
    x = x, y = 308, w = bw, h = bh,
    label = text.start_game,
    primary = true,
    act = function() ctx.sm:set("settings") end,
  }

  -- M12：输入种子重玩某一局
  s.buttons[2] = ui.button{
    x = x, y = 392, w = bw, h = bh,
    label = text.menu_seed_btn,
    act = function() ctx.sm:set("seed") end,
  }

  s.buttons[3] = ui.button{
    x = x, y = 476, w = bw, h = bh,
    label = text.quit,
    act = function() ctx.quit() end,
  }

  function s:enter()
    self.focus = 1
    print("[state] menu")
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
      self.focus = (self.focus - 2) % n + 1        -- 循环上移
    elseif key == "down" or key == "s" then
      self.focus = (self.focus % n) + 1            -- 循环下移
    elseif key == "return" or key == "kpenter" or key == "space" then
      self:activate(self.focus)
    end
  end

  function s:draw(u)
    local mx, my = u and u.mouseX, u and u.mouseY

    ui.center(text.title,   "big",  124, const.COLOR_TEXT)
    ui.center(text.tagline, "tiny", 208, const.COLOR_TEXT_DIM)

    local st   = ctx.settings
    local diff = (st and st.difficulty) or 4

    -- 统计行：最高分 + 胜率合成一行（模板由 text.stats 挑，0 局不会出现 nan）
    local best, wins, games, pct = persist.statsFor(st, diff)
    local line = text.stats(best, wins, games, pct, false)
    if line then
      ui.center(line, "tiny", 246, const.COLOR_TEXT_DIM)
    end

    -- 上一局的种子：只在本次会话里有效（不落盘），冷启动不显示
    if ctx.lastSeed then
      ui.center(string.format(text.menu_seed,
        seed.format(ctx.lastSeed), text.suitCount(ctx.lastSeedDiff or 4)),
        "tiny", 274, const.COLOR_TEXT_DIM)
    end

    for i, b in ipairs(self.buttons) do
      ui.drawButton(b, ui.hit(b, mx, my), i == self.focus)
    end

    ui.center(text.nav_hint, "tiny", 636, const.COLOR_TEXT_DIM)
  end

  return s
end

return M
