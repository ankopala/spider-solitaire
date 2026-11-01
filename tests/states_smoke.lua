-- tests/states_smoke.lua —— M6 终端验证脚本（状态机 + 四个状态的键鼠逻辑）
--
-- 用法（必须在项目根目录运行）：
--   /opt/homebrew/bin/lua tests/states_smoke.lua
--
-- 本脚本不依赖 LÖVE。
--
-- 为什么能脱离 LÖVE 测界面状态？
--   states 模块只在 draw() 里碰 love.graphics，require 阶段什么都不做。
--   所以本脚本只调 enter / keypressed / mousepressed / update，不调 draw。
--   渲染是否正确由真窗口探针截图负责（.workbuddy/screenshots/m6_*.png）。

local scriptPath = (arg and arg[0]) or ""
local root = string.match(scriptPath, "^(.*)/tests/[^/]*$")
if root and #root > 0 then
  package.path = root .. "/?.lua;" .. root .. "/?/init.lua;" .. package.path
end

local const        = require("const")
local animMod      = require("src.anim")
local game         = require("src.game")
local layout       = require("src.layout")
local persist      = require("src.persist")
local seedMod      = require("src.seed")
local text         = require("src.text")
local statemachine = require("src.statemachine")
local menu         = require("src.states.menu")
local settings     = require("src.states.settings")
local seedState    = require("src.states.seed")
local playing      = require("src.states.playing")
local leaveState   = require("src.states.leave")
local resign       = require("src.states.resign")
local won          = require("src.states.won")
local seedboxMod   = require("src.seedbox")

-- ===== 断言小工具 =====
local passed, failed = 0, 0

local function check(name, cond)
  if cond then
    passed = passed + 1
    print("  [PASS] " .. name)
  else
    failed = failed + 1
    print("  [FAIL] " .. name)
  end
end

local function section(title)
  print("")
  print(title)
  print(string.rep("-", 62))
end

-- ===== 工具 =====

local function makeRng(seed)
  local s = seed
  return function(n)
    s = (s * 1103515245 + 12345) % 2147483648
    return (s % n) + 1
  end
end

-- 假状态机：只记录"被切到哪个状态"，不真的切（单元测试用）
local function makeCtx(difficulty, seed)
  local counter = 0

  local ctx = {
    settings = { difficulty = difficulty or 4 },
    -- M12：状态层只认这两个注入，不再有 ctx.rng。
    -- newRng 用同一套 LCG，于是"同种子 -> 同牌局"可以在终端断言。
    newRng = function(s) return makeRng(s) end,
    makeSeed = function()
      counter = counter + 1
      return 100000 + counter          -- 每次不同，模拟"自动抽一个种子"
    end,
    log      = {},
    lastArg  = nil,
  }
  ctx.sm = {
    set = function(_, name, arg)
      ctx.log[#ctx.log + 1] = name
      ctx.lastArg = arg
      return { name = name }
    end,
    is = function(_, name) return false end,
  }
  ctx.quit = function() ctx.log[#ctx.log + 1] = "quit" end
  return ctx
end

local function lastLog(ctx)
  return ctx.log[#ctx.log]
end

-- ===== 1. 状态机本体 =====
section("1. statemachine：set / enter / leave 顺序")

local trace = {}

local stateA = {
  enter = function(self, arg) trace[#trace + 1] = "A.enter:" .. tostring(arg) end,
  leave = function(self, nextName) trace[#trace + 1] = "A.leave:" .. tostring(nextName) end,
}
local stateB = {
  enter = function() trace[#trace + 1] = "B.enter" end,
  -- 故意不实现 leave / update / draw
}

local smLib = statemachine.new({ a = stateA, b = stateB })

check("初始 name = nil", smLib.name == nil)
check("初始 current() = nil", smLib:current() == nil)

smLib:set("a", 42)
check("enter 收到透传参数", trace[1] == "A.enter:42")
check("is('a') 为 true", smLib:is("a") == true)
check("current() 是状态表本身", smLib:current() == stateA)

smLib:set("b")
check("先 leave 旧状态，再 enter 新状态",
  trace[2] == "A.leave:b" and trace[3] == "B.enter")

local okMissing = pcall(function()
  smLib:update(0.1)      -- B 没有 update
  smLib:draw()           -- B 没有 draw
  smLib:mousepressed(1, 2, 1)
end)
check("状态没实现某方法时不报错", okMissing == true)

local okUnknown, errUnknown = pcall(function() smLib:set("nope") end)
check("切到未知状态会报错", okUnknown == false)
check("错误信息点名了未知状态",
  type(errUnknown) == "string" and string.find(errUnknown, "nope", 1, true) ~= nil)

-- ===== 2. 菜单 =====
section("2. menu：焦点移动与激活")

local ctx2 = makeCtx()
local m = menu.new(ctx2)
m:enter()

check("进入时焦点在第 1 项", m.focus == 1)
m:keypressed("down")
check("↓ 到第 2 项", m.focus == 2)
m:keypressed("down")
check("↓ 到第 3 项", m.focus == 3)
m:keypressed("down")
check("↓ 到底后循环回第 1 项", m.focus == 1)
m:keypressed("up")
check("↑ 从第 1 项循环到最后一项（3）", m.focus == 3)

-- 三个菜单项的含义：Start / Play a seed / Quit
ctx2.log = {}
m.focus = 2
m:keypressed("return")
check("第 2 项是 Play a seed", lastLog(ctx2) == "seed")

ctx2.log = {}
m.focus = 3
m:keypressed("return")
check("第 3 项是退出", lastLog(ctx2) == "quit")

ctx2.log = {}
m.focus = 1
m:keypressed("return")                        -- 第 1 项 = Start
check("第 1 项进 settings", lastLog(ctx2) == "settings")

-- 鼠标：点在按钮内部命中，点在空白处不触发
ctx2.log = {}
local b1 = m.buttons[1]
m:mousepressed(b1.x + 5, b1.y + 5, 1)
check("点中 Start 按钮 → settings", lastLog(ctx2) == "settings")

ctx2.log = {}
m:mousepressed(5, 5, 1)
check("点空白不触发任何切换", #ctx2.log == 0)

ctx2.log = {}
m:mousepressed(b1.x + 5, b1.y + 5, 2)
check("右键不触发按钮", #ctx2.log == 0)
check("按钮矩形内命中检测正确", require("src.ui").hit(b1, b1.x + b1.w, b1.y + b1.h) == true)

-- ===== 3. 难度 + 提示方式 =====
section("3. settings：选难度 / 选提示方式 / 开始 / 返回")

local ctx3 = makeCtx(4)
local st = settings.new(ctx3)
st:enter()

check("焦点落在当前难度（4 花色 = 第 3 项）", st.focus == 3)
check("默认提示方式是 auto", ctx3.settings.hintMode == "auto")
check("按钮数 = 3 难度 + 2 提示方式 + Start + Back", #st.buttons == 7)

st:keypressed("2")
check("按 2 直接选 2 花色", ctx3.settings.difficulty == 2)
check("焦点跟到第 2 项", st.focus == 2)

st:keypressed("1")
check("按 1 选 1 花色", ctx3.settings.difficulty == 1)

st:keypressed("4")
check("按 4 选 4 花色", ctx3.settings.difficulty == 4)

-- 选难度本身不切状态
ctx3.log = {}
st:activate(1)
check("点选难度只改设置，不切状态", ctx3.settings.difficulty == 1 and #ctx3.log == 0)

-- 提示方式：点选 / h 键来回切
ctx3.log = {}
st:activate(st.idxHintBtn)
check("选 Hint button 只改设置，不切状态",
  ctx3.settings.hintMode == "button" and #ctx3.log == 0)

st:keypressed("h")
check("h 键切回 auto", ctx3.settings.hintMode == "auto")
st:keypressed("h")
check("h 键再切到 button", ctx3.settings.hintMode == "button")
ctx3.settings.hintMode = "auto"          -- 复位，后面的用例不依赖它

-- 开始 / 返回
ctx3.log = {}
st:activate(st.idxStart)
check("Start → playing", lastLog(ctx3) == "playing")

ctx3.log = {}
st:keypressed("escape")
check("Esc → menu", lastLog(ctx3) == "menu")

-- 键盘导航：Start 的下一项是 Back，再上一项回到 Start
ctx3.log = {}
st.focus = st.idxStart
st:keypressed("down")
check("Start 的下一项是 Back", st.focus == st.idxBack)
st:keypressed("up")
st:keypressed("return")
check("焦点在 Start 时 Enter → playing", lastLog(ctx3) == "playing")

-- ===== 4. 游戏中 =====
section("4. playing：开局 / 退选 / 离开确认 / 重发")

local ctx4 = makeCtx(2)
local pl = playing.new(ctx4)
pl:enter()

check("开局有牌局对象", pl.g ~= nil)
check("难度来自 settings（2 花色）", pl.g.difficulty == 2)
check("stock 50 张", #pl.g.stock == 50)
check("10 列全部非空", (function()
  for i = 1, const.COLS do
    if #pl.g.tableau[i] == 0 then return false end
  end
  return true
end)())
check("手牌 + stock = 104 张", (function()
  local n = #pl.g.stock
  for i = 1, const.COLS do n = n + #pl.g.tableau[i] end
  return n == 104
end)())

-- 点一张正面牌 → 选中
local col1 = pl.g.tableau[1]
local cx = const.colX(1) + const.CARD_W / 2
local cy = layout.cardY(col1, #col1) + 20
pl:mousepressed(cx, cy, 1)
check("点顶牌可以选中", pl.g.selected ~= nil)
check("按下牌身就建了 drag（拖拽的前提）", pl.drag ~= nil)

-- 真的拖起来：位移超过阈值后 dragOffset 才有值
pl:mousemoved(cx + const.DRAG_START * 2, cy + 40)
check("拖动超过阈值后 dragOffset 非空", pl:dragOffset() ~= nil)

-- 有选中时 Esc 只取消选中，不弹框、不切状态
ctx4.log = {}
pl:keypressed("escape")
check("Esc 取消选中", pl.g.selected == nil)
check("Esc 取消选中时清掉拖拽（和右键一致）", pl.drag == nil and pl:dragOffset() == nil)
check("Esc 取消选中时不切状态", #ctx4.log == 0)

-- 没选中时 Esc 打开"离开确认"，不再直接回菜单（M15）
ctx4.log = {}
pl:keypressed("escape")
check("Esc 打开离开确认（不是直接回菜单）", lastLog(ctx4) == "leave")
check("确认框拿到的是同一个牌局对象", ctx4.lastArg ~= nil and ctx4.lastArg.game == pl.g)

local lv4 = leaveState.new(ctx4)
lv4:enter(ctx4.lastArg)
ctx4.log = {}
lv4:activate(lv4.idxKeep)
check("Keep playing → 回 playing", lastLog(ctx4) == "playing")
check("Keep playing 带 resume（不重发牌）", ctx4.lastArg ~= nil and ctx4.lastArg.resume == true)

-- 重发牌
ctx4.log = {}
local oldGame = pl.g
pl:keypressed("r")
check("R 换了新牌局对象", pl.g ~= oldGame)
check("新牌局仍是 50 张 stock", #pl.g.stock == 50)
check("重发牌不切状态", #ctx4.log == 0)

-- F1 调试开关
local before = pl.showDebug
pl:keypressed("f1")
check("F1 切换调试浮层", pl.showDebug ~= before)

-- ===== 4b. 提示：auto 自己报 / button 等你问 =====
section("4b. 提示：两种模式的行为差异")

-- 摆一副死局：10 列各 1 张偶数点（+1 都是奇数，场上没有），stock 空
local function stuckGame()
  local g = {
    tableau = {}, stock = {},
    foundations = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 },
    score = 500, moves = 0, selected = nil, message = "",
    history = {}, events = {}, difficulty = 2,
  }
  local ranks = { 2, 4, 6, 8, 10, 12, 2, 4, 6, 8 }
  for i = 1, const.COLS do
    g.tableau[i] = { { suit = "spades", rank = ranks[i], faceUp = true } }
  end
  return g
end

local ctxA = makeCtx(2, 4242)              -- hintMode 缺省 → auto
local plA = playing.new(ctxA)
plA:enter()
plA.g = stuckGame()
plA.hintDirty = true
plA:update(0.05)

check("auto 模式：死局会被算出来", plA.hintKind == "stuck")
check("auto 模式：底部提示条是 stuck", plA:notice() ~= nil and plA:notice().kind == "stuck")

plA.g.selected = { col = 1, index = 1 }
check("拿着选中的牌时不弹提示条", plA:notice() == nil)
plA.g.selected = nil

-- button 模式：不自动算，也不自动弹
local ctxB = makeCtx(2, 4242)
ctxB.settings.hintMode = "button"
local plB = playing.new(ctxB)
plB:enter()
plB.g = stuckGame()
plB.hintDirty = true
plB:update(0.05)

check("button 模式：不会自动计算", plB.hintKind == "moves" and plB.hint == nil)
check("button 模式：平时不弹提示条", plB:notice() == nil)

plB:keypressed("h")
check("button 模式按 H → 指向 Undo", plB.hint ~= nil and plB.hint.kind == "undo")
check("此时底部才说那一句话", plB:notice() ~= nil and plB:notice().kind == "stuck")

plB:update(const.HINT_HOLD + 0.1)
check("高亮到点自动消失", plB.hint == nil)
check("提示条跟着消失", plB:notice() == nil)

-- ===== 4c. 连按 H：在候选之间循环（M14）=====
section("4c. 连按 H 在候选之间循环")

-- 三候选牌局：9♠ 能落到三个 10 上，三手同分（都是"清空列 +25"），
-- 所以顺序完全由 (from,index,to) 的次键决定 → 依次 to = 2, 3, 4。
-- 填充列刻意不含 8 / 10：8 会落到 9 上、10 会接住 9，都会多造候选。
local function cycleGame(multi)
  local g = {
    tableau = {}, stock = {},
    foundations = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 },
    score = 500, moves = 0, selected = nil, message = "",
    history = {}, events = {}, difficulty = 2,
  }
  for i = 1, const.COLS do g.tableau[i] = {} end
  g.tableau[1] = { { suit = "spades", rank = 9,  faceUp = true } }
  g.tableau[2] = { { suit = "hearts", rank = 10, faceUp = true } }

  if multi then
    g.tableau[3] = { { suit = "clubs",    rank = 10, faceUp = true } }
    g.tableau[4] = { { suit = "diamonds", rank = 10, faceUp = true } }
    local fill = { 2, 4, 6, 12, 2, 4, 6 }
    for k = 1, #fill do
      g.tableau[4 + k] = { { suit = "spades", rank = fill[k], faceUp = true } }
    end
  else
    local fill = { 2, 4, 6, 12, 2, 4, 6, 12 }
    for k = 1, #fill do
      g.tableau[2 + k] = { { suit = "spades", rank = fill[k], faceUp = true } }
    end
  end
  return g
end

local ctxC = makeCtx(2, 4242)
ctxC.settings.hintMode = "button"
local plC = playing.new(ctxC)
plC:enter()
plC.g = cycleGame(true)

local function clickCol(p, col)
  p:mousepressed(const.colX(col) + const.CARD_W / 2, const.TABLEAU_Y + 20, 1)
end

plC:keypressed("h")
check("第 1 次 H → 第 1 个候选", plC.hint ~= nil and plC.hint.kind == "move"
  and plC.hint.index == 1 and plC.hint.total == 3)
check("同分时先给 (from,index,to) 最小的（落到 col2）", plC.hint.move.to == 2)
check("底部显示 1 / 3", plC:notice() ~= nil and plC:notice().text:find("1 / 3", 1, true) ~= nil)

plC:keypressed("h")
check("第 2 次 H → 第 2 个", plC.hint.index == 2 and plC.hint.move.to == 3)
check("底部显示 2 / 3", plC:notice().text:find("2 / 3", 1, true) ~= nil)

plC:keypressed("h")
check("第 3 次 H → 第 3 个", plC.hint.index == 3 and plC.hint.move.to == 4)
check("每次按都重新亮满 3 秒", plC.hint.t == 0)

plC:keypressed("h")
check("第 4 次 H 回绕到第 1 个", plC.hint.index == 1 and plC.hint.move.to == 2)

plC:update(const.HINT_HOLD + 0.1)
check("高亮到点消失", plC.hint == nil)
plC:keypressed("h")
check("淡出后再按是下一个（位置属于牌桌，不属于可见性）", plC.hint.index == 2)

-- 单纯"选中一张牌"不算牌桌变化：列表不该作废，循环不该被打回第 1 个。
-- 这正是 hintListDirty 必须与 hintDirty 分开的原因（后者每次左键都置 true）。
clickCol(plC, 1)
check("只选中不算牌桌变化", plC.hintListDirty == false)
check("点击会收起旧高亮", plC.hint == nil)
plC:keypressed("h")
check("选中过之后按 H 仍然前进", plC.hint.index == 3)

-- 真走一步：9♠ 落到 col2 的 10♥ 上
clickCol(plC, 1)
clickCol(plC, 2)
check("真走一步后高亮被清掉", plC.hint == nil)
check("真走一步后候选列表作废", plC.hintListDirty == true and plC.g.moves == 1)

plC:keypressed("h")
check("重算后回到第 1 个", plC.hint.index == 1 and plC.hint.total == 3)
-- ⚠ 这里不能断言"落空列 col1 排第一"：那一手是上一步的逆操作（-500），
--    它排最后而不是最前。第一名是 9♠ 落到另一个 10 上（0 分）。
check("重算后的首选来自新牌桌（col2 的 9♠）", plC.hint.move.from == 2 and plC.hint.move.index == 2)

-- 只有一条路时不显示 1 / 1（对玩家没有信息量）
local ctxD = makeCtx(2, 4242)
ctxD.settings.hintMode = "button"
local plD = playing.new(ctxD)
plD:enter()
plD.g = cycleGame(false)
plD:keypressed("h")
check("只有一条路时仍然给答案", plD.hint ~= nil and plD.hint.index == 1 and plD.hint.total == 1)
check("1 / 1 不占提示条", plD:notice() == nil)

-- ===== 5. 胜利切转（带延迟）=====
section("5. playing → won：延迟切换")

local ctx5 = makeCtx(4)
local pl2 = playing.new(ctx5)
pl2:enter()

-- 没赢的时候 update 不该切
ctx5.log = {}
pl2:update(1.0)
check("没胜利时不切状态", #ctx5.log == 0)

-- 人为凑满 8 组
pl2.g.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }
pl2:update(0.1)
check("刚赢的瞬间还不切（留时间看收组）", #ctx5.log == 0)
pl2:update(0.8)
check("累计超过 0.8s 后切到 won", lastLog(ctx5) == "won")
check("切转时传了摘要", type(ctx5.lastArg) == "table")
check("摘要里带牌局对象", ctx5.lastArg.game == pl2.g)
check("摘要里带分数/步数",
  ctx5.lastArg.score == pl2.g.score and ctx5.lastArg.moves == pl2.g.moves)

-- M11：首次通关应当同时记下最高分，并把它透传给结算屏。
-- 注意 makeCtx 的 settings 里本来没有 best 表，也没有 saveSettings ——
-- 这正好覆盖"老结构 + 没注入落盘函数"这两条降级路径。
check("摘要里带最高分，且标为破纪录",
  ctx5.lastArg.best == pl2.g.score and ctx5.lastArg.isNewBest == true)
check("最高分写回了 ctx.settings",
  ctx5.settings.best ~= nil and ctx5.settings.best[4] == pl2.g.score)

-- ===== 6. 结算屏 =====
section("6. won：再玩一局 / 回菜单")

local ctx6 = makeCtx(4)
local w = won.new(ctx6)
local fakeGame = { foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 } }
w:enter({ game = fakeGame, difficulty = 4, score = 1200, moves = 87 })

check("记住摘要", w.summary.score == 1200 and w.summary.moves == 87)
check("记住牌局（当背景画）", w.g == fakeGame)

ctx6.log = {}
w:keypressed("return")
check("Enter → playing", lastLog(ctx6) == "playing")

ctx6.log = {}
w:keypressed("escape")
check("Esc → menu", lastLog(ctx6) == "menu")

ctx6.log = {}
w:keypressed("r")
check("R → playing（再来一局）", lastLog(ctx6) == "playing")

ctx6.log = {}
w:mousepressed(w.buttons[2].x + 5, w.buttons[2].y + 5, 1)
check("点 Main menu 按钮 → menu", lastLog(ctx6) == "menu")

ctx6.log = {}
w:mousepressed(w.buttons[1].x + 5, w.buttons[1].y + 5, 1)
check("点 Play again 按钮 → playing", lastLog(ctx6) == "playing")

w:leave()
check("离开时松掉牌局引用", w.g == nil and w.summary == nil)

-- ===== 7. 全链路：menu → settings → playing → won → menu =====
section("7. 真状态机跑一遍完整闭环")

-- 设置屏的按钮数量会变（M9 加了两个），所以焦点不能再按固定次数按 down，
-- 而是一路 down 到 Start 为止。
local function focusStart(sm)
  local stt = sm.states.settings
  for _ = 1, #stt.buttons do
    if stt.focus == stt.idxStart then return end
    sm:keypressed("down")
  end
end

local ctx7 = makeCtx(4)
local sm7 = statemachine.new({}, ctx7)
ctx7.sm = sm7
sm7.states.menu     = menu.new(ctx7)
sm7.states.settings = settings.new(ctx7)
sm7.states.playing  = playing.new(ctx7)
sm7.states.leave    = leaveState.new(ctx7)
sm7.states.won      = won.new(ctx7)

sm7:set("menu")
check("起点是 menu", sm7:is("menu") == true)

sm7:keypressed("return")                 -- Start
check("menu → settings", sm7:is("settings") == true)

sm7:keypressed("2")                      -- 选 2 花色
check("难度写成 2", ctx7.settings.difficulty == 2)

focusStart(sm7)
sm7:keypressed("return")
check("settings → playing", sm7:is("playing") == true)
check("新牌局用的是刚选的难度", sm7.states.playing.g.difficulty == 2)

-- 人为凑满 8 组，等延迟过去
sm7.states.playing.g.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }
sm7:update(0.9)
check("playing → won", sm7:is("won") == true)
check("won 拿到了牌局", sm7.states.won.g == sm7.states.playing.g)

sm7:keypressed("escape")                 -- 回菜单
check("won → menu", sm7:is("menu") == true)
check("回菜单后焦点复位到第 1 项", sm7.states.menu.focus == 1)

-- 再来一局：应重新发牌，且旧牌局不被复用
local prevGame = sm7.states.playing.g
sm7:keypressed("return")
focusStart(sm7)
sm7:keypressed("return")
check("第二次进入 playing 会重新发牌", sm7.states.playing.g ~= prevGame)

-- ===== 8. 认输面板（M10）=====
section("8. 认输：三个出口 + 同一副牌重开")

local ctx8 = makeCtx(4, 8888)
local sm8  = statemachine.new({}, ctx8)
ctx8.sm = sm8
sm8.states.menu     = menu.new(ctx8)
sm8.states.settings = settings.new(ctx8)
sm8.states.playing  = playing.new(ctx8)
sm8.states.leave    = leaveState.new(ctx8)
sm8.states.resign   = resign.new(ctx8)
sm8.states.won      = won.new(ctx8)

sm8:set("playing")
local g8   = sm8.states.playing.g
local snap = game.dump(g8)          -- 开局那张牌桌的文本指纹

-- 1) 点 HUD 上的 Resign
sm8:mousepressed(const.RESIGN_X + 10, const.RESIGN_Y + 10, 1)
check("点 HUD 的 Resign → resign 状态", sm8:is("resign") == true)
check("当前牌局一起传过去", sm8.states.resign.g == g8)

-- 先把牌局弄"脏"，否则"重开"和"没动过"看起来一样
g8.score = 320
g8.moves = 27
check("牌局确实脏了（和开局指纹不同）", game.dump(g8) ~= snap)

-- 2) Restart this deal
local rs = sm8.states.resign
local rb = rs.buttons[rs.idxRestart]
sm8:mousepressed(rb.x + rb.w / 2, rb.y + rb.h / 2, 1)
check("Restart → 回 playing", sm8:is("playing") == true)
check("分数回到 500", g8.score == 500)
check("步数归零", g8.moves == 0)
check("牌桌恢复成开局那一副（同一副牌、同样的位置）", game.dump(g8) == snap)
check("撤销栈也清空了", game.undoDepth(g8) == 0)

-- 3) Keep playing
sm8:mousepressed(const.RESIGN_X + 10, const.RESIGN_Y + 10, 1)
local cb = sm8.states.resign.buttons[sm8.states.resign.idxCancel]
sm8:mousepressed(cb.x + cb.w / 2, cb.y + cb.h / 2, 1)
check("Keep playing → 回 playing", sm8:is("playing") == true)
check("牌局是同一个（没有被重发）", sm8.states.playing.g == g8)

-- 4) New deal
local oldG = g8
sm8:mousepressed(const.RESIGN_X + 10, const.RESIGN_Y + 10, 1)
local nb = sm8.states.resign.buttons[sm8.states.resign.idxNew]
sm8:mousepressed(nb.x + nb.w / 2, nb.y + nb.h / 2, 1)
check("New deal → 回 playing", sm8:is("playing") == true)
check("换了一副新牌", sm8.states.playing.g ~= oldG)
check("新牌是满的（50 张 stock）", #sm8.states.playing.g.stock == 50)

-- 5) Esc 必须落在无害的那个出口
sm8:mousepressed(const.RESIGN_X + 10, const.RESIGN_Y + 10, 1)
check("又进了 resign", sm8:is("resign") == true)
sm8:keypressed("escape")
check("Esc = Keep playing", sm8:is("playing") == true)

-- 6) 键盘焦点循环（只按键，不确认 —— 确认会真的切状态）
local rs2 = resign.new(ctx8)
rs2:enter({ game = sm8.states.playing.g })
check("焦点从第 1 项开始", rs2.focus == 1)
rs2:keypressed("down")
check("↓ → 第 2 项", rs2.focus == 2)
rs2:keypressed("up")
rs2:keypressed("up")
check("↑↑ 绕过顶端回到第 3 项", rs2.focus == 3)

-- 7) playing:enter 的 resume 语义
local plr = playing.new(ctx8)
plr:enter()
local ga = plr.g
plr:enter({ resume = true })
check("带 resume 不改牌局", plr.g == ga)
plr:enter()
check("不带 resume 会重新发牌", plr.g ~= ga)

-- 8) 按钮几何
check("Resign 在 HUD 里，不压牌桌", const.RESIGN_Y + const.RESIGN_H <= const.HUD_H)
check("不在任何一列的落点带里",
  layout.columnBandAt(const.RESIGN_X + 10, const.RESIGN_Y + 10) == nil)
check("和底部的 Undo / Hint 不在同一行", const.RESIGN_Y + const.RESIGN_H < const.UNDO_Y)
check("中心命中", layout.hitTestResign(const.RESIGN_X + const.RESIGN_W / 2,
  const.RESIGN_Y + const.RESIGN_H / 2) == true)
check("左边界外不命中", layout.hitTestResign(const.RESIGN_X - 1,
  const.RESIGN_Y + 10) == false)

-- ===== 8b. 离开确认（M15）=====
section("8b. 离开确认：Esc 不再直接回菜单，三个出口全都不记账")

-- 真状态机 + 会数落盘次数的 ctx（不改 makeCtx —— 它故意没有 saveSettings）
local function makeLeaveCtx()
  local c = makeCtx(4, 4321)
  c.saves = 0
  c.saveSettings = function() c.saves = c.saves + 1 end
  return c
end

local ctx9 = makeLeaveCtx()
local sm9  = statemachine.new({}, ctx9)
ctx9.sm = sm9
sm9.states.menu    = menu.new(ctx9)
sm9.states.playing = playing.new(ctx9)
sm9.states.leave   = leaveState.new(ctx9)

sm9:set("playing")
local g9    = sm9.states.playing.g
local snap9 = game.dump(g9)          -- 开局那张牌桌的文本指纹

check("开局是空局（moves == 0）—— 空局不做特例", g9.moves == 0)

sm9:keypressed("escape")
check("空局按 Esc 也弹确认框", sm9:is("leave") == true)
check("弹框时把牌局传给面板（背景要画这一局）", sm9.states.leave.g == g9)
check("弹框本身不动牌局", game.dump(g9) == snap9)

local lv9 = sm9.states.leave
check("焦点落在 Keep playing", lv9.focus == lv9.idxKeep)
check("Keep playing 是 primary", lv9.buttons[lv9.idxKeep].primary == true)
check("Main menu 垫底（破坏性动作不抢焦点）", lv9.idxMenu == #lv9.buttons)

lv9:keypressed("up")
check("↑ 从第 1 项绕过顶端到 Main menu", lv9.focus == lv9.idxMenu)
lv9:keypressed("down")
check("↓ 从最后一项绕过底部回到 Keep playing", lv9.focus == lv9.idxKeep)
for _ = 1, 3 do lv9:keypressed("down") end
check("↓ 三次绕一圈回到 Keep playing", lv9.focus == lv9.idxKeep)

-- 两个面板长得几乎一样，但这里的 "3" 是最坏出口 —— 刻意不给数字快捷键
lv9:keypressed("3")
check("数字键 3 在离开面板里不直选（不会直接退出到菜单）", sm9:is("leave") == true)
lv9:keypressed("1")
check("数字键 1 也不直选", sm9:is("leave") == true and lv9.focus == lv9.idxKeep)

sm9:keypressed("escape")
check("Esc = Keep playing", sm9:is("playing") == true)
check("Keep playing 走 resume：还是同一副牌", sm9.states.playing.g == g9)
check("牌桌没被动过", game.dump(g9) == snap9)

-- 把牌局弄"脏"，否则"重开"和"没动过"看起来一样
g9.score = 320
g9.moves = 27
check("牌局确实脏了（和开局指纹不同）", game.dump(g9) ~= snap9)

sm9:keypressed("escape")
check("再次 Esc 又弹框", sm9:is("leave") == true)
local lv9b = sm9.states.leave
local rb9  = lv9b.buttons[lv9b.idxRestart]
sm9:mousepressed(rb9.x + rb9.w / 2, rb9.y + rb9.h / 2, 1)
check("Restart this deal → 回 playing", sm9:is("playing") == true)
check("Restart 后分数回到开局值", g9.score == const.SCORE_START)
check("Restart 后步数归零", g9.moves == 0)
check("Restart 后牌桌恢复成开局那一副（同一副牌、同样的位置）", game.dump(g9) == snap9)
check("Restart 后撤销栈清空", game.undoDepth(g9) == 0)

sm9:keypressed("escape")
check("第三次 Esc 弹框", sm9:is("leave") == true)
local lv9c = sm9.states.leave
local mb9  = lv9c.buttons[lv9c.idxMenu]
sm9:mousepressed(mb9.x + mb9.w / 2, mb9.y + mb9.h / 2, 1)
check("Main menu → menu", sm9:is("menu") == true)
-- 记账表到现在本该完全没被碰过：recordResult 一次都没跑，所以连字段都不存在。
-- 这比断言 "games[4] == 0" 更强 —— 后者分不清"记了 0 局"和"根本没记"。
check("三个出口都没动过统计表（games 仍是 nil）", ctx9.settings.games == nil)
check("也没有记胜局（wins 仍是 nil）", ctx9.settings.wins == nil)
check("三个出口一次都没落盘", ctx9.saves == 0)

-- 面板几何：用 s 上存的 px/py/pw/ph，不在测试里重抄 660/372
local lvG = leaveState.new(ctx9)
lvG:enter({ game = g9 })
local inPanel = true
for _, b in ipairs(lvG.buttons) do
  if b.x < lvG.px or b.y < lvG.py
     or b.x + b.w > lvG.px + lvG.pw
     or b.y + b.h > lvG.py + lvG.ph then inPanel = false end
end
check("三个按钮都在面板矩形内", inPanel)

local noOverlap = true
for i = 1, #lvG.buttons - 1 do
  if lvG.buttons[i].y + lvG.buttons[i].h >= lvG.buttons[i + 1].y then noOverlap = false end
end
check("三个按钮互不重叠", noOverlap)

lvG:leave()
check("离开面板时松掉牌局引用", lvG.g == nil)
lvG:enter({ game = g9 })
lvG.focus = lvG.idxMenu
lvG:enter({ game = g9 })
check("第二次打开时焦点复位到 Keep playing", lvG.focus == lvG.idxKeep)

-- M19：种子不再嵌在说明句里，说明行只剩"不记账"那一句 —— 宽度用字符数代理守住
-- （终端里量不到字体宽度；tiny 下数字最宽 ≈ 11.47px，按 660 宽反推上限）。
local panelCharsMax = math.floor(660 / 11.47)
check("离开说明行装得进面板", #text.leave_lede <= panelCharsMax)
check("认输说明行装得进面板", #text.resign_lede <= panelCharsMax)

-- 动画期：Esc 挂起，播完再弹（不是丢弃、也不是立刻冻结画面）
local ctx10 = makeLeaveCtx()
local sm10  = statemachine.new({}, ctx10)
ctx10.sm = sm10
sm10.states.playing = playing.new(ctx10)
sm10.states.leave   = leaveState.new(ctx10)
sm10:set("playing")

local pl10 = sm10.states.playing
pl10:update(0.01)          -- 第一帧把 g.events 搬进动画队列，busy 才会为真
check("（前提）开局发牌动画确实在拦输入", animMod.busy(pl10.anim) == true)

sm10:keypressed("escape")
check("动画期间 Esc 不立刻切状态", sm10:is("playing") == true)
check("动画期间 Esc 被挂起，没有被吞掉", pl10.pendingLeave == true)

for _ = 1, 40 do
  if sm10:is("leave") then break end
  pl10:update(0.1)
end
check("动画播完后自动弹确认框", sm10:is("leave") == true)
check("挂起标记已清，不会弹第二次", pl10.pendingLeave == false)

-- 已获胜展示期：Esc 既不弹框也不回菜单（账已经记完了，没有"留下"的诉求）
local ctx11 = makeLeaveCtx()
local sm11  = statemachine.new({}, ctx11)
ctx11.sm = sm11
sm11.states.playing = playing.new(ctx11)
sm11.states.leave   = leaveState.new(ctx11)
sm11.states.won     = won.new(ctx11)
sm11:set("playing")

local pl11 = sm11.states.playing
pl11:update(0.01)
sm11:keypressed("escape")
check("（前提）动画期 Esc 被挂起", pl11.pendingLeave == true)

pl11.g.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }
pl11:update(0.01)          -- 这一帧判定为胜：挂起的请求必须被丢弃
check("赢了之后挂起的 Esc 被丢弃", pl11.pendingLeave == false)

sm11:keypressed("escape")
check("已获胜展示期按 Esc 既不弹框", sm11:is("playing") == true)
check("也没有直接回菜单", sm11:is("menu") == false)

for _ = 1, 12 do pl11:update(0.1) end
check("0.8 秒后自己走到结算屏", sm11:is("won") == true)

-- ===== 8c. 种子复制控件（M19）=====
section("8c. 种子复制：Esc / 认输 / 结算三屏共用同一个控件")

-- 剪贴板走 ctx 注入（状态层不许碰 love.system）——测试里塞两个假函数数次数。
-- 这条"能数次数"的性质就是注入的唯一理由：状态里如果直接调 love.system，
-- 终端测试根本加载不了这些文件。
local function makeClipCtx(seedNum)
  local c = makeCtx(4, seedNum or 24680)
  c.saves = 0
  c.saveSettings = function() c.saves = c.saves + 1 end
  c.clip, c.clipCalls, c.readClip = nil, 0, ""
  c.setClipboard = function(v) c.clip = v; c.clipCalls = c.clipCalls + 1 end
  c.getClipboard = function() return c.readClip end
  return c
end

local ctxC = makeClipCtx()
local smC  = statemachine.new({}, ctxC)
ctxC.sm = smC
smC.states.playing = playing.new(ctxC)
smC.states.leave   = leaveState.new(ctxC)
smC:set("playing")
local gC = smC.states.playing.g
smC:keypressed("escape")

local lvC  = smC.states.leave
local boxC = lvC.box

check("控件整组在面板内", boxC.x >= lvC.px and boxC.x + boxC.w <= lvC.px + lvC.pw)
check("复制按钮在种子方框右侧", boxC.btnX >= boxC.chipX + boxC.chipW)
check("控件压不到第一个出口按钮", boxC.y + boxC.h <= lvC.buttons[1].y)
check("控件两侧各留 ≥ 40px", boxC.w <= lvC.pw - 80)
check("复制按钮不在焦点链里（出口仍是 3 项）", #lvC.buttons == 3)

-- 方框是"值"，按钮才是"动作"：点方框不该动剪贴板
smC:mousepressed(boxC.chipX + 10, boxC.y + boxC.h / 2, 1)
check("点种子方框不复制", ctxC.clipCalls == 0)

local snapC = game.dump(gC)
smC:mousepressed(boxC.btnX + boxC.btnW / 2, boxC.y + boxC.h / 2, 1)
check("点 Copy 写进剪贴板", ctxC.clipCalls == 1)
check("复制的是补零后的 10 位种子", ctxC.clip == seedMod.format(gC.seed))
check("复制内容恰好 DIGITS 位且全数字",
  #ctxC.clip == seedMod.DIGITS and string.match(ctxC.clip, "^%d+$") ~= nil)
check("复制不切状态（还留在确认框里）", smC:is("leave") == true)
check("复制不动牌桌", game.dump(gC) == snapC)
check("复制不落盘、不记账", ctxC.saves == 0 and ctxC.settings.games == nil)
check("复制后按钮切成 Copied", boxC.copiedT > 0)

lvC:update(const.SEEDBOX_HOLD + 0.05)
check("1.2 秒后自己退回 Copy", boxC.copiedT == 0)

smC:keypressed("c")
check("c 键也能复制", ctxC.clipCalls == 2)

smC:keypressed("escape")
check("复制过之后 Esc 仍是 Keep playing", smC:is("playing") == true)

-- 认输面板：同一套控件，但它的出口里有一个会记账 —— 复制绝不能碰到它
local ctxRc = makeClipCtx()
local rsC   = resign.new(ctxRc)
rsC:enter({ game = gC })
rsC:mousepressed(rsC.box.btnX + 4, rsC.box.y + 4, 1)
check("认输面板的 Copy 也写剪贴板", ctxRc.clip == seedMod.format(gC.seed))
check("认输面板复制不记账、不落盘", ctxRc.saves == 0 and ctxRc.settings.games == nil)
check("认输面板复制不切状态", #ctxRc.log == 0)

-- 结算屏：label 还要带难度（一局的身份是 seed + difficulty）
local ctxWc = makeClipCtx()
local wsC   = won.new(ctxWc)
wsC:enter({ game = gC, difficulty = 4, score = 500, moves = 12 })
check("结算屏的种子行带难度",
  wsC:boxText() == string.format(text.won_seed, seedMod.format(gC.seed), text.suitCount(4)))
check("结算屏控件在面板内、在按钮之上",
  wsC.box.x >= wsC.px and wsC.box.x + wsC.box.w <= wsC.px + wsC.pw
  and wsC.box.y + wsC.box.h <= wsC.buttons[1].y)
check("结算屏出口仍是 2 项（复制不进焦点链）", #wsC.buttons == 2)
check("结算屏方框用的是加宽版", wsC.box.chipW == const.SEEDBOX_CHIP_W_LONG)
-- 270px 这个宽度是按"今天这行最长的样子"定的：字符串再变长就得重新量宽度。
check("结算屏种子行不超过 27 字符", #(wsC:boxText()) <= 27)
wsC:mousepressed(wsC.box.btnX + 4, wsC.box.y + 4, 1)
-- ⚠ 复制的必须是纯数字，不是那行显示文字（" (4 suits)" 不该进剪贴板）
check("结算屏 Copy 写的是纯种子数字", ctxWc.clip == seedMod.format(gC.seed))
check("结算屏复制不切状态", #ctxWc.log == 0)

-- 没有牌局：不画、也点不中（别留一个点了没反应的空框）
local ctxN = makeClipCtx()
local lvN  = leaveState.new(ctxN)
lvN:enter({})
check("没有牌局时没有显示文字", seedboxMod.text(lvN.g) == nil)
check("没有牌局时也没有可复制的值", seedboxMod.value(lvN.g) == nil)
lvN:mousepressed(lvN.box.btnX + 4, lvN.box.y + 4, 1)
check("没有牌局时点 Copy 不写剪贴板", ctxN.clipCalls == 0)

-- 没注入 setClipboard（就是 makeCtx 的常态）：不崩，也绝不假报成功
local ctxQ = makeCtx(4, 13579)
local lvQ  = leaveState.new(ctxQ)
lvQ:enter({ game = gC })
lvQ:mousepressed(lvQ.box.btnX + 4, lvQ.box.y + 4, 1)
check("没有剪贴板注入时不崩、也不假报 Copied", lvQ.box.copiedT == 0)

-- ===== 9. 种子屏 =====
section("9. 种子屏：输入 / 退格 / 清空 / 开局")

local ctxS = makeCtx(4)
local sd   = seedState.new(ctxS)
sd:enter()

check("进入时缓冲为空", sd.buf == "")
check("显示全是占位符", seedMod.display(sd.buf) == string.rep("-", seedMod.DIGITS))

sd:keypressed("1")
sd:keypressed("2")
check("输入两位", sd.buf == "12")

sd:keypressed("backspace")
check("退格删一位", sd.buf == "1")

sd:keypressed("a")
check("字母不进缓冲", sd.buf == "1")

sd:keypressed("delete")
check("delete 清空", sd.buf == "")

ctxS.log = {}
sd:keypressed("return")
check("空输入按 Enter 不切换", #ctxS.log == 0 and sd.msg ~= "")

sd:keypressed("7")
ctxS.log = {}
sd:keypressed("return")
check("输入 7 按 Enter → playing，种子里是 7",
  lastLog(ctxS) == "playing" and ctxS.lastArg.seed == 7)

ctxS.log = {}
sd:keypressed("escape")
check("Esc 回菜单", lastLog(ctxS) == "menu")

-- --- 粘贴（M19）---
-- Cmd+V 在 LÖVE 里同样产生 keypressed("v")，所以这里绑的就是裸 "v"。
sd:enter()
check("（前提）重新进入后缓冲为空", sd.buf == "")

ctxS.getClipboard = function() return "  12ab34  " end
sd:keypressed("v")
check("粘贴只取其中的数字", sd.buf == "1234")

sd:keypressed("delete")            -- 每个用例从空缓冲开始，别让上一次的残留影响判断
sd.msg = "old"
ctxS.getClipboard = function() return "seed 0000123456789" end
sd:keypressed("v")
check("带着前缀的整句也能粘，且按 DIGITS 截断",
  sd.buf == string.sub("0000123456", 1, seedMod.DIGITS))
check("粘贴成功后清掉报错行", sd.msg == "")

sd:keypressed("delete")
sd:keypressed("1")                 -- 先手动敲 5 位，再粘 8 位 → 补满 10 位
for _ = 2, 5 do sd:keypressed("1") end
ctxS.getClipboard = function() return "99999999" end
sd:keypressed("v")
check("已有内容时是补齐而不是覆盖",
  sd.buf == string.rep("1", 5) .. string.rep("9", seedMod.DIGITS - 5))

ctxS.getClipboard = function() return "1234567890" end
sd:keypressed("v")
check("缓冲满了再粘不动", #sd.buf == seedMod.DIGITS)

sd:keypressed("delete")
check("（前提）delete 清空", sd.buf == "")
ctxS.getClipboard = nil
sd:keypressed("v")
check("没注入剪贴板时按 v 不崩、也不改缓冲", sd.buf == "")

ctxS.getClipboard = function() return "seed 42" end
sd:keypressed("v")
check("粘一句带前缀的话也能用", sd.buf == "42")

-- ===== 10. 同种子同一局 =====
section("10. 同种子同一局")

local function playingWithSeed(s)
  local ctx = makeCtx(4)
  local pl  = playing.new(ctx)
  pl:enter({ seed = s })
  return pl
end

local plA = playingWithSeed(123456)
local plB = playingWithSeed(123456)
local plC = playingWithSeed(123457)

check("同种子两次开局，dump 完全相同", game.dump(plA.g) == game.dump(plB.g))
check("不同种子，dump 不同", game.dump(plA.g) ~= game.dump(plC.g))
check("种子记在 g.seed 上", plA.g.seed == 123456)
check("ctx.lastSeed 记下这一局", plA.ctx.lastSeed == 123456)
check("ctx.lastSeedDiff 记下难度", plA.ctx.lastSeedDiff == 4)

-- ===== 11. 自动种子 / R 重发 / resume =====
section("11. 自动种子、R 重发、resume")

local ctxR = makeCtx(4)
local plR  = playing.new(ctxR)
plR:enter()

local firstSeed = plR.g.seed
check("没有指定种子时自动抽一个", type(firstSeed) == "number")

plR:keypressed("r")
check("R 换成另一个种子", plR.g.seed ~= firstSeed)
check("R 之后允许重新记账", plR.resultRecorded == false)

local dumpBefore = game.dump(plR.g)
local seedBefore = plR.g.seed
plR:enter({ resume = true })
check("resume 保留牌局", game.dump(plR.g) == dumpBefore)
check("resume 保留种子", plR.g.seed == seedBefore)

-- ===== 12. 胜率记账：哪些分支该计、哪些不该 =====
section("12. 胜率记账：赢 / 认输 / 不该计的分支")

-- 没记过任何结果时 settings.games 整张表都不存在，读的时候要兜住
local function gamesOf(ctx, d)
  return (ctx.settings.games and ctx.settings.games[d]) or 0
end

local ctxW = makeCtx(4)
local plW  = playing.new(ctxW)
plW:enter()
plW.g.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }

plW:update(0.01)                      -- 赢的第一帧就记账，不等 0.8s
check("赢的第一帧 games+1", ctxW.settings.games[4] == 1)
check("wins 同时 +1", ctxW.settings.wins[4] == 1)

plW:update(0.01)
check("再 update 不会重复记", ctxW.settings.games[4] == 1)

local histBefore = #plW.g.history
plW:keypressed("z")
check("赢后按 Z 不能撤销（输入已锁）", #plW.g.history == histBefore)

-- 认输 → New deal：加一局，不加胜局
local ctxL = makeCtx(4)
local plL  = playing.new(ctxL)
plL:enter()
local rsnL = resign.new(ctxL)
rsnL:enter({ game = plL.g })

ctxL.log = {}
rsnL:activate(rsnL.idxNew)
check("Resign → New deal 记一局", ctxL.settings.games[4] == 1)
check("但不记胜局", (ctxL.settings.wins[4] or 0) == 0)
check("并且切回 playing", lastLog(ctxL) == "playing")

-- Restart this deal / Keep playing / Esc 都不计
local ctxK = makeCtx(4)
local plK  = playing.new(ctxK)
plK:enter()
local rsnK = resign.new(ctxK)
rsnK:enter({ game = plK.g })

rsnK:activate(rsnK.idxRestart)
check("Restart this deal 不计局数", gamesOf(ctxK, 4) == 0)

rsnK:enter({ game = plK.g })
rsnK:activate(rsnK.idxCancel)
check("Keep playing 不计局数", gamesOf(ctxK, 4) == 0)

ctxK.log = {}
plK:keypressed("escape")
check("Esc 打开离开确认（不再直接回菜单）", lastLog(ctxK) == "leave")
check("Esc 弹框不计局数", gamesOf(ctxK, 4) == 0)

local lvK = leaveState.new(ctxK)
lvK:enter({ game = plK.g })
ctxK.log = {}
lvK:activate(lvK.idxMenu)
check("从确认框点 Main menu 才回菜单", lastLog(ctxK) == "menu")
check("Main menu 也不计局数", gamesOf(ctxK, 4) == 0)

-- R 重发也不计：换了一副牌，但上一局没有"结论"
local ctxRR = makeCtx(4)
local plRR = playing.new(ctxRR)
plRR:enter()
plRR:keypressed("r")
check("R 重发不计局数", gamesOf(ctxRR, 4) == 0)

-- ===== 13. 结算摘要带上统计 =====
section("13. 结算摘要带胜率")

local ctxSum = makeCtx(4)
local plSum  = playing.new(ctxSum)
plSum:enter()
plSum.g.foundations = { spades = 2, hearts = 2, diamonds = 2, clubs = 2 }
plSum:update(0.01)
plSum:update(0.9)                     -- 越过 WIN_DELAY，切到 won

check("摘要里有 wins / games / pct",
  ctxSum.lastArg.wins == 1 and ctxSum.lastArg.games == 1 and ctxSum.lastArg.pct == 100)
check("摘要里有 best", type(ctxSum.lastArg.best) == "number")

-- text.stats 的四档模板：0 局必须是 nil，不能给 "0/0"
check("text.stats 在 0 局时返回 nil",
  require("src.text").stats(0, 0, 0, nil, false) == nil)
check("text.stats 只有 best 时只显示 best",
  require("src.text").stats(1200, 0, 0, nil, false) == "best 1200")

-- ===== 14. 开发调试键（M13）：w 造局 / j 直跳 / 绝不写盘 =====
section("14. dev 键：w 造局 / j 直跳 / 绝不写盘")

-- ctx.dev 只能由 main.lua 注入（那里才读 SPIDER_DEV）。
-- 测试里手动打开，并挂一个"落盘计数器"——
-- 现有的 makeCtx 故意没有 saveSettings，那条"没注入落盘函数"的降级路径要继续保留，
-- 所以这里另建一个 ctx，不要去改 makeCtx。
local function makeDevCtx(difficulty)
  local c = makeCtx(difficulty or 4)
  c.dev = true
  c.saves = 0
  c.saveSettings = function() c.saves = c.saves + 1 end
  return c
end

-- --- 14.1 开关关着时，两个键必须完全不存在 ---
local ctxOff = makeCtx(4)
local plOff  = playing.new(ctxOff)
plOff:enter()
local dumpOff = game.dump(plOff.g)

plOff:keypressed("w")
plOff:keypressed("j")

check("dev 关：w / j 都不切状态", #ctxOff.log == 0)
check("dev 关：牌桌一个字段都没动", game.dump(plOff.g) == dumpOff)
check("dev 关：devWin 仍是 nil", plOff.devWin == nil)
check("dev 关：没有凭空造出结算摘要", ctxOff.lastArg == nil)

-- --- 14.2 j：立刻切、摘要正确、牌桌已是真实终局 ---
local ctxJ = makeDevCtx(4)
local plJ  = playing.new(ctxJ)
plJ:enter()
ctxJ.log = {}

plJ:keypressed("j")

check("dev 开：j 立刻切到 won", #ctxJ.log == 1 and lastLog(ctxJ) == "won")

local sj = ctxJ.lastArg
check("摘要 = 第 1 档（1240 / 8 / 12 / 67）",
  sj.best == 1240 and sj.wins == 8 and sj.games == 12 and sj.pct == 67)
check("第 1 档不是破纪录", sj.isNewBest == false)
check("摘要的牌局就是当前牌局（背景才画得对）", sj.game == plJ.g)
check("摘要的分数/步数取自牌局", sj.score == plJ.g.score and sj.moves == plJ.g.moves)
check("j 之后是终局牌桌（8 组 / 空 stock / 空列）",
  game.foundationTotal(plJ.g) == 8 and #plJ.g.stock == 0
  and #plJ.g.tableau[1] == 0 and #plJ.g.tableau[10] == 0)
check("j 之后一次都没落盘", ctxJ.saves == 0)
check("j 之后 settings 里没有 best / games / wins",
  ctxJ.settings.best == nil and ctxJ.settings.games == nil
  and ctxJ.settings.wins == nil)
check("j 之后牌局种子还在（结算页要显示 seed 行）", plJ.g.seed ~= nil)

-- --- 14.3 w：走真实 update 路径 + 0.8 秒延迟 ---
local ctxW = makeDevCtx(4)
local plW  = playing.new(ctxW)
plW:enter()
plW:update(0.01)                     -- 让开局发牌动画进队列

check("开局发牌动画确实在拦输入（证明 w 必须插在闸之前）",
  animMod.busy(plW.anim) == true)

ctxW.log = {}
plW:keypressed("w")

check("w 无视 busy 闸，并把动画清干净",
  game.foundationTotal(plW.g) == 8
  and animMod.busy(plW.anim) == false
  and animMod.collecting(plW.anim) == false)

plW:update(0.01)
check("w 之后第一帧不切（还没到 0.8s）", #ctxW.log == 0)
plW:update(0.78)
check("累计 0.79s 仍然不切", #ctxW.log == 0)
plW:update(0.02)
check("越过 0.8s 才切到 won", lastLog(ctxW) == "won")
check("w 也走假统计（不是真实的 0 局）",
  ctxW.lastArg.best == 1240 and ctxW.lastArg.games == 12)

check("w 全程没落盘", ctxW.saves == 0)
check("w 之后 settings 没被写",
  ctxW.settings.best == nil and ctxW.settings.games == nil)
check("w 关掉了记账闸（recordWin 直接拒绝）",
  plW.resultRecorded == true and plW:recordWin() == false)

-- leave 里还有一次幂等兜底，同样不能写盘
plW:leave()
check("离开 playing 也不会补记一笔", ctxW.saves == 0)

-- --- 14.4 结算屏上连按 j：三档循环，回到第 1 档 ---
local ctxV = makeDevCtx(4)
local plV  = playing.new(ctxV)
plV:enter()
plV:keypressed("j")                  -- 跳到结算屏，此时是第 1 档

local wv = won.new(ctxV)
wv:enter(ctxV.lastArg)

check("进结算屏显示第 1 档 normal",
  wv.summary.best == 1240 and wv.summary.isNewBest == false)

wv:keypressed("j")
check("按第 1 次 → 第 2 档 new best（同数字 + 高亮）",
  wv.summary.best == 1240 and wv.summary.isNewBest == true)

wv:keypressed("j")
check("按第 2 次 → 第 3 档 extreme（99999 / 999 / 999 / 100）",
  wv.summary.best == 99999 and wv.summary.wins == 999
  and wv.summary.games == 999 and wv.summary.pct == 100)

wv:keypressed("j")
check("按第 3 次 → 回到第 1 档（三档循环）",
  wv.summary.best == 1240 and wv.summary.isNewBest == false)

check("结算屏切档位不动 settings", ctxV.saves == 0 and ctxV.settings.games == nil)
check("结算屏切档位不动牌局（背景 / seed 保持真实）",
  wv.summary.game == plV.g and wv.summary.score == plV.g.score)

-- --- 14.5 赢下之后 R 被锁；新局入口要清掉 devWin ---
local ctxR = makeDevCtx(4)
local plR  = playing.new(ctxR)
plR:enter()
plR:keypressed("w")
check("造局后 devWin 已设上", plR.devWin ~= nil)

-- 赢了之后 R 会被 isWon 那道闸锁住（真实赢局也是这样），牌局不该被换掉
local seedBefore = plR.g.seed
plR:keypressed("r")
check("赢下之后 R 是锁死的（没换牌局）", plR.g.seed == seedBefore)
check("没换局自然也不清 devWin", plR.devWin ~= nil)

plR:enter({ resume = true })          -- 从认输面板 Keep playing 回来
check("resume 不清 devWin（牌局没换）", plR.devWin ~= nil)
plR:enter()                            -- 真正开新局
check("enter 开新局清 devWin", plR.devWin == nil)

-- 汇总
print("")
print(string.rep("=", 62))
print(string.format("RESULT: %d passed, %d failed", passed, failed))
print(string.rep("=", 62))

if failed > 0 then os.exit(1) end
