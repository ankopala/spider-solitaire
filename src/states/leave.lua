-- src/states/leave.lua —— 离开牌桌的确认面板（M15）
--
-- 为什么是独立状态，而不是给 resign.lua 加一个 mode 参数？
--   两个面板长得几乎一样，但【记账后果】正好相反：
--     resign 的 "New deal" 是"这一局有结论了"的失败出口 → games+1 / wins+0，
--                            全项目唯一调用 persist.recordResult(false) 的地方；
--     leave  的三个出口全部不计账 —— Esc 离开从来不算输。
--   合成一个文件，最自然的写法就是"公共收尾里看 mode 决定记不记账"，而 s:leave 两边都会跑：
--   一旦有人把 recordResult 挪进 s:leave，Esc 离开就开始偷偷记输，而且只有"打开过离开面板"
--   的用例才会露头。一屏一套出口，改错得改两处才会出事。
--
-- ⚠ 命名：状态名 "leave" 与状态机的生命周期钩子 s:leave 同名（SM:set 里调的就是
--   prev:leave(nextName)）。下面的 s:leave 就是那个钩子，别在这里再放一个叫 leave 的字段。
--
-- enter 的入参：{ game = 当前牌局 }
--   三个出口（顺序即无害程度）：
--     Keep playing       切回 playing 并保留牌局（Esc 也落这里）
--     Restart this deal  game.restart(g) → 同一副牌、同样的发牌顺序重开
--     Main menu          切到 menu，这一局丢掉
--
-- 刻意【不】给 1/2/3 直选：resign 里 1 = Restart、3 = Keep playing（最安全）；
-- 这里 1 = Keep、3 = Main menu（最坏）。两个面板长得几乎一样，靠肌肉记忆按数字迟早出事。
--
-- M19：那行种子带一个 Copy 小按钮（见 src/seedbox.lua），点一下写进系统剪贴板，
--   方便抄到「Play a seed」屏去重玩。复制走 ctx.setClipboard 注入 —— 状态层的
--   mousepressed 不许碰 love。面板因此从 372 高变 404：种子从说明句里拆出来单独一行。

local const  = require("const")
local game   = require("src.game")
local render = require("src.render")
local seedbox = require("src.seedbox")
local text   = require("src.text")
local ui     = require("src.ui")

local M = {}

function M.new(ctx)
  local s = {
    ctx     = ctx,
    g       = nil,      -- enter 时由 summary.game 填入
    focus   = 1,        -- 键盘焦点下标
    buttons = {},       -- ui.button 数组
    t       = 0,        -- 只用于淡入
  }

  -- ===== 版式：只算一次，挂到 s 上 =====
  -- resign.lua 把同一组数字在 new() 和 draw() 各写了一遍，改一处漏一处就是
  -- "按钮在 A 处、面板在 B 处"。这里存成字段，draw 直接用，测试也能量。
  --
  -- M19：ph 372 → 404。多出来的一行是"种子方框 + Copy 按钮"：
  -- 原来种子里嵌在说明句中间，插不进按钮，只能拆成两行。
  s.pw, s.ph = 660, 404
  s.px = (const.VW - s.pw) / 2
  s.py = (const.VH - s.ph) / 2 - 6

  -- 种子控件：方框在面板正中偏左，复制按钮紧跟其右（整组居中）
  s.box = seedbox.new{
    cx = s.px + s.pw / 2,
    y  = s.py + 120,
  }

  local bw, bh = 540, 62
  local bx     = s.px + (s.pw - bw) / 2
  local by0    = s.py + 162
  local gap    = 8

  -- 顺序不是随意的：无害的在最上面（初始焦点 + Esc 的落点），破坏性的垫底。
  -- primary 给 Keep playing —— 和 resign 相反：那边的主诉求是"重开"，这边是"回去继续"。
  s.idxKeep = #s.buttons + 1
  s.buttons[s.idxKeep] = ui.button{
    x = bx, y = by0, w = bw, h = bh, kind = "option",
    label = text.leave_keep.name,
    sub   = text.leave_keep.sub,
    primary = true,
    act = function()
      -- ⚠ 必须带 resume：不带的话 playing:enter 会重新发牌，玩家点的是"继续"不是"重开"
      ctx.sm:set("playing", { resume = true })
    end,
  }

  s.idxRestart = #s.buttons + 1
  s.buttons[s.idxRestart] = ui.button{
    x = bx, y = by0 + (bh + gap), w = bw, h = bh, kind = "option",
    label = text.leave_restart.name,
    sub   = text.leave_restart.sub,
    act = function()
      -- 就地重置（同一副牌）再带 resume 回去：playing:enter 要是重新发牌，
      -- 玩家刚挑的那个"重开"就白选了。
      -- ⚠ 守卫 s.g：game.restart 直接读 g.initial，没有牌局时会崩。
      -- ⚠ 闭包里用 s 而不是 self —— 按钮是普通函数，调用时没有 self。
      if s.g then game.restart(s.g) end
      ctx.sm:set("playing", { resume = true })
    end,
  }

  s.idxMenu = #s.buttons + 1
  s.buttons[s.idxMenu] = ui.button{
    x = bx, y = by0 + (bh + gap) * 2, w = bw, h = bh, kind = "option",
    label = text.leave_menu.name,
    sub   = text.leave_menu.sub,
    act = function()
      -- 不记账、不落盘：这一局没有"结论"，只是玩家不玩了。
      -- playing:leave 只会调幂等的 recordWin()，未胜利时什么都不做。
      ctx.sm:set("menu")
    end,
  }

  function s:enter(summary)
    self.g     = summary and summary.game or nil
    self.focus = s.idxKeep          -- 每次打开都回到无害出口
    self.t     = 0
    self.box:reset()                -- 上次那句 "Copied" 不该跟着新面板一起出来
    print("[state] leave")
  end

  -- 只推进面板的淡入。牌桌在底下是静止的：状态机不会再调 playing:update，
  -- 所以"面板开着的时候胜利倒计时还在走"这种事不会发生。
  function s:update(dt)
    self.t = self.t + dt
    self.box:update(dt)             -- "Copied" 的 1.2 秒倒计时
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
    -- 复制按钮先判：它是"读操作"，混进下面那轮循环会让人以为它也是个出口。
    -- ⚠ 它【不在】s.buttons 里 —— 焦点链仍是 3 项，↑↓ 的绕圈行为一个字都不用改。
    if self.box:click(mx, my, seedbox.value(self.g), self.ctx) then return end
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
    elseif key == "c" then
      -- 顺手给个键位。刻意【不】给 1/2/3：这里 1 = Keep、3 = Main menu，
      -- 和 resign 的数字键语义正相反，见文件头。
      self.box:copy(seedbox.value(self.g), self.ctx)
    elseif key == "escape" then
      -- Esc = 反悔。这个面板是"确认破坏性操作"，默认出口必须是无害的那个。
      self:activate(self.idxKeep)
    end
  end

  function s:draw(u)
    local mx, my = u and u.mouseX, u and u.mouseY

    if self.g then
      -- 牌桌当背景：让玩家看清自己要离开的是哪一局。
      -- 这里传的是 main 给的裸 ui（只有 mouseX/mouseY）→ 没有 showResign，
      -- 所以 HUD 上不会画 Resign 按钮（和 resign.lua 一样）。
      render.draw(self.g, u)
    end

    -- 面板淡入（0.18s）。用 alpha 不用位移：按钮是绝对坐标，跟着动会对不齐。
    local k = math.min(1, (self.t or 0) / 0.18)

    ui.dim(const.HUD_H, 0.82 * k)
    ui.panel(self.px, self.py, self.pw, self.ph, k)

    ui.center(text.leave_title, "big", self.py + 26, const.COLOR_TEXT, k)

    -- 说明只剩"不记账"这一句。种子从 M19 起单独占一行（方框 + Copy 按钮）——
    -- 原来它嵌在这句话中间，中间插不进按钮。回去之后菜单上那行 "last seed"
    -- 仍然能把这一局找回来。
    ui.center(text.leave_lede, "tiny", self.py + 94, const.COLOR_TEXT_DIM, k)

    -- 种子 + 复制按钮。没有牌局（或没有种子）时 label 是 nil，这里什么都不画，
    -- 点它也不会命中 —— 不留一个点了没反应的空框。
    self.box:draw(seedbox.text(self.g), k, mx, my)

    for i, b in ipairs(self.buttons) do
      -- 第 5 个参数 checked 显式传 false：这些是"动作"不是"选项"，
      -- 不传的话 drawButton 会退回"焦点即当前值"的老行为，在焦点按钮右侧画一个方块 ——
      -- 看着像"这一项已经选中了"，其实这里根本没有"当前值"这回事。
      ui.drawButton(b, ui.hit(b, mx, my), i == self.focus, k, false)
    end

    ui.center(text.nav_hint, "tiny", self.py + self.ph - 26, const.COLOR_TEXT_DIM, k)
  end

  return s
end

return M
