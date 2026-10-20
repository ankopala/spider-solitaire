-- src/states/settings.lua —— 设置：难度（1 / 2 / 4 花色）+ 提示方式（auto / button）
--
-- 两项都只写进 ctx.settings，真正生效的地方：
--   difficulty → playing:enter 发牌时用（见 src/deck.lua 的 suitPlan）
--   hintMode   → playing 决定"自己说"还是"放着按钮等你问"
--
-- ⚠ 按钮下标一律走具名字段（idxStart / idxBack / idxHintAuto / idxHintBtn），
--   不要再按下标写死。M9 插了两个 hint 按钮，之前 tests 里的 activate(4) 就全错位了。

local const = require("const")
local text  = require("src.text")
local ui    = require("src.ui")

local M = {}

local DIFFS = { 1, 2, 4 }
local HINTS = { "auto", "button" }

-- ===== 版式 =====
-- 两段式：上面三个难度（占满宽），下面两个提示方式（并排）。
-- 选项是"标题 + 说明"两行，整体垂直居中（见 ui.drawButton）—— 高度改了不用再调偏移。
local OW, OH   = 560, 64
local OX       = (const.VW - OW) / 2
local DIFF_Y0  = 218
local DIFF_GAP = 68                  -- 64 高 + 4 间隙
local HINT_Y   = 454
local HINT_GAP = 16
local HINT_W   = (OW - HINT_GAP) / 2 -- 272

-- 当前难度对应的按钮下标（找不到就落回 4 花色）
local function diffIndex(d)
  for i, v in ipairs(DIFFS) do
    if v == d then return i end
  end
  return 3
end

function M.new(ctx)
  local s = { ctx = ctx, focus = 1, buttons = {} }

  if ctx.settings.hintMode == nil then ctx.settings.hintMode = "auto" end

  -- 改完设置立刻落盘（M10）。ctx.saveSettings 由 main.lua 注入 ——
  -- 本文件不碰 love，所以终端测试里可以不传，这里用 if 兜一下。
  local function save()
    if ctx.saveSettings then ctx.saveSettings() end
  end

  for i, d in ipairs(DIFFS) do
    local info = text.diff[d]
    s.buttons[i] = ui.button{
      x = OX, y = DIFF_Y0 + (i - 1) * DIFF_GAP, w = OW, h = OH,
      kind = "option",
      label = info.name,
      sub = info.sub,
      act = function() ctx.settings.difficulty = d; save() end,
    }
  end

  s.idxHintAuto = #s.buttons + 1
  s.idxHintBtn  = #s.buttons + 2

  for k, mode in ipairs(HINTS) do
    local info = text.hint_mode[mode]
    s.buttons[#s.buttons + 1] = ui.button{
      x = OX + (k - 1) * (HINT_W + HINT_GAP), y = HINT_Y, w = HINT_W, h = OH,
      kind = "option",
      label = info.name,
      sub = info.sub,
      act = function() ctx.settings.hintMode = mode; save() end,
    }
  end

  local bw, bh = 340, 54
  local bx = (const.VW - bw) / 2

  s.idxStart = #s.buttons + 1
  s.buttons[s.idxStart] = ui.button{
    x = bx, y = 532, w = bw, h = bh,
    label = text.start_game,
    primary = true,
    act = function() ctx.sm:set("playing") end,
  }

  s.idxBack = #s.buttons + 1
  s.buttons[s.idxBack] = ui.button{
    x = bx, y = 596, w = bw, h = bh,
    label = text.back,
    act = function() ctx.sm:set("menu") end,
  }

  -- 某个 hint 模式对应的按钮下标
  local function hintIndex(mode)
    return mode == "button" and s.idxHintBtn or s.idxHintAuto
  end

  function s:enter()
    self.focus = diffIndex(ctx.settings.difficulty)
    print(string.format("[state] settings (difficulty=%d, hintMode=%s)",
      ctx.settings.difficulty, ctx.settings.hintMode))
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
    elseif key == "escape" then
      ctx.sm:set("menu")
    elseif key == "1" or key == "2" or key == "4" then
      -- 数字键直达：不要求先挪焦点
      local d = tonumber(key)
      ctx.settings.difficulty = d
      self.focus = diffIndex(d)
      save()
    elseif key == "h" then
      -- 和数字键选难度同一套思路：一个键在两档之间来回切
      ctx.settings.hintMode = (ctx.settings.hintMode == "button") and "auto" or "button"
      self.focus = hintIndex(ctx.settings.hintMode)
      save()
      print("[settings] hintMode = " .. ctx.settings.hintMode)
    end
  end

  function s:draw(u)
    local mx, my = u and u.mouseX, u and u.mouseY

    ui.center(text.settings_title, "big",  84, const.COLOR_TEXT)
    ui.center(text.settings_hint,  "tiny", 160, const.COLOR_TEXT_DIM)

    ui.left(text.sec_difficulty, "tiny", OX, 192, const.COLOR_TEXT_DIM)
    ui.left(text.sec_hints,      "tiny", OX, 428, const.COLOR_TEXT_DIM)

    for i, b in ipairs(self.buttons) do
      -- active 决定底色/描边（含键盘焦点），checked 决定右侧那个"当前值"方块
      local checked = false
      if i <= #DIFFS then
        checked = (ctx.settings.difficulty == DIFFS[i])
      elseif i == s.idxHintAuto then
        checked = (ctx.settings.hintMode == "auto")
      elseif i == s.idxHintBtn then
        checked = (ctx.settings.hintMode == "button")
      end

      ui.drawButton(b, ui.hit(b, mx, my), checked or i == self.focus, nil, checked)
    end

    ui.center(text.settings_keys_hint, "tiny", 664, const.COLOR_TEXT_DIM)
  end

  return s
end

return M
