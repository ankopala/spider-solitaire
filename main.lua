-- main.lua —— 入口：窗口 / 缩放 / 把事件转发给状态机（M6）
--
-- 职责收缩成三件事，其它都交给状态：
--   1. 建窗口、加载字体、构造 ctx（设置 / 随机源 / 退出）
--   2. 虚拟坐标 1280x720 <-> 真实窗口 的 letterbox 变换
--   3. 把 update / draw / 鼠标 / 键盘原样转发给当前状态
--
-- 想改界面流程，请看 src/states/*.lua；想改规则，看 src/rules.lua 与 src/game.lua。

local const        = require("const")
local persist      = require("src.persist")
local render       = require("src.render")
local seed         = require("src.seed")     -- 纯逻辑：种子的取值范围只在那边定义
local statemachine = require("src.statemachine")

local menu     = require("src.states.menu")
local settings = require("src.states.settings")
local playing  = require("src.states.playing")
local resign   = require("src.states.resign")
local won      = require("src.states.won")
local seedState = require("src.states.seed")

local sm                       -- 状态机（ctx.sm 指向同一个对象）

-- ===== 随机：每局一个可复现的生成器（M12）=====
--
-- 以前 ctx.rng 直接指向 love.math.random，那是 LÖVE 的【全局】生成器：
-- 状态只前进、无法回退，所以"同一个种子发回同一副牌"根本做不到。
-- 现在每局按种子新建一个独立生成器，全局生成器不再参与发牌。
--
-- 这两个函数注入到 ctx，状态层只管调用，不直接碰 love。

local seedCounter = 0

local function makeSeed()
  seedCounter = seedCounter + 1
  -- 不依赖全局 RNG 的播种方式：墙钟秒 + 启动以来微秒 + 会话序号。
  -- 序号保证"同一秒内连开两局"也不会撞种子。
  --
  -- ⚠ 上限只来自 seed.SPAN。以前这里写的是 `% 900000 + 100000`，
  --   那是独立于 seed.MAX 的第二套上限：改成 10 位时只改 seed.lua 会全绿，
  --   但玩家新开的局仍然是 6 位。取值范围必须有唯一来源。
  --
  -- 精度：os.time()*131 ≈ 2.33e11，该区间 double 的 ulp ≈ 5e-5，
  -- 远小于 1，所以每个整数都能精确表示（2^53 ≈ 9e15，还有约 4 个数量级余量）。
  local frac = math.floor(love.timer.getTime() * 1000000)
  return seed.wrap(os.time() * 131 + frac + seedCounter * 7919)
end

local function newRng(s)
  local gen = love.math.newRandomGenerator(s)
  -- rng(n) 的契约是返回 [1, n] 的整数，正好是 RandomGenerator:random(n) 的行为
  return function(n) return gen:random(n) end
end

-- ===== 视口：虚拟坐标 <-> 真实窗口 =====

local function getView()
  local sw, sh = love.graphics.getDimensions()
  local scale = math.min(sw / const.VW, sh / const.VH)
  local ox = (sw - const.VW * scale) / 2
  local oy = (sh - const.VH * scale) / 2
  return scale, ox, oy
end

local function mouseToVirtual(mx, my)
  local scale, ox, oy = getView()
  return (mx - ox) / scale, (my - oy) / scale
end

-- ===== LÖVE 回调 =====

function love.load()
  love.graphics.setBackgroundColor(const.COLOR_BG)
  render.load()                                   -- 字体只建一次

  -- 设置的读写口（M10）。persist.lua 本身不认识 love，靠这两个闭包落盘，
  -- 所以它的解析逻辑能在终端被测试。文件落在 LÖVE 的存档目录里：
  --   ~/Library/Application Support/LOVE/spider/settings.txt
  local fileStore = {
    read = function()
      if not love.filesystem.getInfo(persist.FILE) then return nil end
      return love.filesystem.read(persist.FILE)
    end,
    write = function(s)
      return love.filesystem.write(persist.FILE, s)
    end,
  }

  -- ===== 开发调试开关（M13）=====
  -- 用 == "1" 而不是"非空即真"：SPIDER_DEV=0 必须是关，否则"我明明关掉了"会变灵异事件。
  --
  -- 只在这一处读环境变量。状态层自己 os.getenv 虽然能跑（它不是 love），
  -- 但会让终端测试跟着 shell 环境走 —— export 一下就让 145 条断言随机挂，
  -- 而且现有检查一条都拦不住。这类静默陷阱不值得省那一行注入。
  --
  -- ⚠ 从访达双击 .app 启动时拿不到 shell 环境，必须从终端带前缀启动才有效。
  --   这是特性不是 bug：正式玩家本来就不该有调试键。
  local devOn = os.getenv("SPIDER_DEV") == "1"

  local ctx = {
    -- 有存档就接着上次的难度 / 提示方式 / 统计；没有（或文件坏了）就用默认值
    settings = persist.load(fileStore),
    dev      = devOn,                             -- true 时 playing / won 才认 w / j
    makeSeed = makeSeed,                          -- 新局的种子
    newRng   = newRng,                            -- 种子 -> rng(n) 闭包
    quit     = function() love.event.quit() end,
    store    = fileStore,
  }

  -- 设置一改就落盘。放在这里而不是 settings.lua 里，因为只有 main 认识 love。
  ctx.saveSettings = function() persist.save(ctx.settings, fileStore) end

  sm = statemachine.new({}, ctx)
  ctx.sm = sm                                     -- 状态通过 ctx.sm:set(...) 跳转

  sm.states.menu     = menu.new(ctx)
  sm.states.settings = settings.new(ctx)
  sm.states.seed     = seedState.new(ctx)
  sm.states.playing  = playing.new(ctx)
  sm.states.resign   = resign.new(ctx)
  sm.states.won      = won.new(ctx)

  sm:set("menu")

  print("Spider Solitaire - menu -> settings -> play")
  print("  in game: click a card then a highlighted column, or drag the run and drop it")
  print("  click stock to deal one card to every column")
  print("  Z / Ctrl+Z or the Undo button = take back the last move")
  print("  H = ask for a hint (settings picks auto notice vs. a Hint button)")
  print("  Resign (top right) = give up: restart the same deal, or deal a fresh one")
  print("  menu > Play a seed = replay a deal from its 10-digit seed")
  print("  Esc = deselect / back to menu    R = redeal    D = dump    F1 = debug overlay")

  -- 调试键只在开了开关时才提。正常启动一个字都不多 —— 这一段和玩家无关。
  if ctx.dev then
    print("  DEV KEYS ON (SPIDER_DEV=1)")
    print("    W = fake a finished deal, then let the real 0.8s countdown run")
    print("    J = jump straight to the win screen   (J again there = next fake stats)")
  end
end

function love.update(dt)
  sm:update(dt)
end

function love.draw()
  local mx, my = love.mouse.getPosition()
  local vx, vy = mouseToVirtual(mx, my)           -- 状态里一律用虚拟坐标

  local scale, ox, oy = getView()
  love.graphics.push()
    love.graphics.translate(ox, oy)
    love.graphics.scale(scale, scale)
    sm:draw({ mouseX = vx, mouseY = vy })
  love.graphics.pop()
end

function love.mousepressed(x, y, button)
  local vx, vy = mouseToVirtual(x, y)
  sm:mousepressed(vx, vy, button)
end

-- 拖拽跟手（M8）：鼠标移动只是更新偏移量，牌局要到松手时才变
function love.mousemoved(x, y)
  local vx, vy = mouseToVirtual(x, y)
  sm:mousemoved(vx, vy)
end

function love.mousereleased(x, y, button)
  local vx, vy = mouseToVirtual(x, y)
  sm:mousereleased(vx, vy, button)
end

function love.keypressed(key)
  sm:keypressed(key)
end
