-- src/states/seed.lua —— 输入种子，重玩某一局（M12）
--
-- 为什么单独一屏：项目没有文本输入控件，而种子是 10 位纯数字，
-- 用"按键 -> 缓冲串"这一层最省事，不需要 IME、光标、选区那一套。
-- 补零 / 截断 / 退格这些字符串逻辑全在 src/seed.lua，这里只管事件与画面。
--
-- ⚠ 与其它状态一样：只在 draw() 里碰 love。enter/keypressed 不许碰。

local const = require("const")
local seed  = require("src.seed")
local text  = require("src.text")
local ui    = require("src.ui")

local M = {}

function M.new(ctx)
  local s = { ctx = ctx, buf = "", msg = "", buttons = {}, focus = 1 }

  local bw, bh = 240, 56
  local y0 = 424

  s.buttons[1] = ui.button{
    x = 390, y = y0, w = bw, h = bh,
    label = text.seed_play,
    primary = true,
    act = function() s:deal() end,
  }

  s.buttons[2] = ui.button{
    x = 390 + bw + 20, y = y0, w = bw, h = bh,
    label = text.seed_back,
    act = function() ctx.sm:set("menu") end,
  }

  -- 每次进来都从空开始。不预填上一次的种子 —— 预填后玩家想输新的
  -- 必须先清空，很容易以为键盘坏了。「上次那局」用下面一行灰字提示。
  function s:enter()
    self.buf   = ""
    self.msg   = ""
    self.focus = 1
    print("[state] seed")
  end

  function s:deal()
    local n = seed.parse(self.buf)
    if not n then
      self.msg = text.seed_empty
      return
    end
    self.ctx.sm:set("playing", { seed = n })
  end

  function s:keypressed(key)
    if key == "escape" then
      self.ctx.sm:set("menu")
      return
    end

    -- Enter 永远是"开局"，不看焦点：这一屏的主操作就是开局。
    if key == "return" or key == "kpenter" then
      self:deal()
      return
    end

    if key == "backspace" then
      self.buf = seed.pop(self.buf)
      self.msg = ""
      return
    end

    if key == "delete" then
      self.buf = ""
      self.msg = ""
      return
    end

    local nextBuf = seed.push(self.buf, key)
    if nextBuf ~= self.buf then
      self.buf = nextBuf
      self.msg = ""
    end
  end

  function s:mousepressed(mx, my, button)
    if button ~= 1 then return end

    for i, b in ipairs(self.buttons) do
      if ui.hit(b, mx, my) then
        self.focus = i
        b.act()
        return
      end
    end
  end

  function s:draw(u)
    local mx, my = u and u.mouseX, u and u.mouseY

    ui.center(text.seed_title, "big",  124, const.COLOR_TEXT)
    ui.center(text.seed_lede,  "tiny", 208, const.COLOR_TEXT_DIM)

    -- 输入框：面板本身就是"这里可以输入"的视觉提示
    ui.panel(440, 248, 400, 88, 1)
    ui.center(seed.display(self.buf), "big", 260, const.COLOR_TEXT)

    -- 当前难度。同一串种子配不同难度不是同一局，所以必须显示出来，
    -- 否则玩家会疑惑"我明明输了同一个种子"。
    ui.center(string.format("difficulty: %s",
      text.suitCount(self.ctx.settings.difficulty)), "tiny", 344, const.COLOR_TEXT_DIM)

    -- 动态行：报错 > 预览将要开的局 > 上一次的种子
    local line, color = nil, const.COLOR_TEXT_DIM
    if self.msg ~= "" then
      line, color = self.msg, const.COLOR_REJECT
    elseif #self.buf > 0 then
      local n = seed.parse(self.buf)
      if n then line = string.format(text.seed_will, seed.format(n)) end
    elseif self.ctx.lastSeed then
      line = string.format(text.seed_last,
        seed.format(self.ctx.lastSeed),
        text.suitCount(self.ctx.lastSeedDiff or 4))
    end
    if line then ui.center(line, "tiny", 376, color) end

    for i, b in ipairs(self.buttons) do
      -- 第 5 参 checked 必须显式传 false：不传会退回"焦点即当前值"，
      -- 在焦点按钮右侧画出一个像"已选中"的方块（M10 踩过）。
      ui.drawButton(b, ui.hit(b, mx, my), i == self.focus, 1, false)
    end

    ui.center(text.seed_hint, "tiny", 636, const.COLOR_TEXT_DIM)
  end

  return s
end

return M
