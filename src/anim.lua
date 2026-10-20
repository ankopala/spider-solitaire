-- src/anim.lua —— 动画队列（纯逻辑，不引用 love）
--
-- 【核心思路】游戏状态永远【领先】于画面。
--
-- 一次移动在 src/game.lua 里是瞬间完成的：牌已经在目标列里了，计分也扣了。
-- 动画不参与任何规则判断，它只是"把这次变化演出来" —— render 拿到一个
-- 短暂的位移偏移量，让那几张牌从旧位置滑回新位置。
--
-- 所以这里不需要保存牌对象，只需要记「哪一列的第几张 → 偏移多少 → 延迟多久」。
-- 状态是真相，动画是字幕。字幕跟不上真相的时候，真相照样是对的。
--
-- 两种 kind：
--   shift    一段（或几张）牌从 (dx, dy) 滑回 0。
--            开局发牌 / 补牌 / 移动全用它 —— 它们本质是同一个动作。
--   collect  13 张牌飞向 foundation 并缩小。
--            牌已经不在桌面上了，所以这一项必须自带牌面数据才能画。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local M = {}

-- ===== 缓动 =====
-- 统一用 easeOutCubic：起步快、收尾慢，符合"牌被甩过去然后停住"的直觉。
-- 线性插值会让牌看起来像是被传送带匀速搬运，不像牌。
function M.easeOutCubic(x)
  if x <= 0 then return 0 end
  if x >= 1 then return 1 end
  local u = 1 - x
  return 1 - u * u * u
end

function M.clamp01(x)
  if x < 0 then return 0 end
  if x > 1 then return 1 end
  return x
end

function M.lerp(a, b, k)
  return a + (b - a) * k
end

-- ===== 队列 =====
-- 一次动作可能连续产生多项（移动 → 收组），它们应该【依次】播，不要叠在一起。
-- 所以这里是最朴素的一条先进先出队列，同一时刻只有 items[1] 在播。

function M.queue()
  return { items = {} }
end

function M.clear(q)
  q.items = {}
end

function M.active(q)
  return q.items[1]
end

-- 队列头部是不是"应该拦住输入"的动画（开局发牌 / 收组）。
-- 短距离的移动动画【不算】—— 那会把连续出牌的手感杀掉。
function M.busy(q)
  local it = q.items[1]
  return it ~= nil and it.blocking == true
end

-- 队列里（正在播或排着）还有没有收组动画。
-- 胜利倒计时只在【收组】上暂停：那 13 张牌正飞进 foundation，切屏会把它剪掉。
-- 开局发牌不算 —— 那一项跟"赢"毫无关系，不该拖住结算。
function M.collecting(q)
  for _, it in ipairs(q.items) do
    if it.kind == "collect" then return true end
  end
  return false
end

-- 一项动画的总时长：shift 由最晚结束的那个 group 决定
local function totalOf(it)
  if it.kind == "shift" then
    local last = 0
    for _, g in ipairs(it.groups or {}) do
      local d = (g.delay or 0) + (g.dur or it.dur)
      if d > last then last = d end
    end
    return last
  end
  return it.dur
end

-- 建「列 → 索引 → group」索引表。
-- 开局那一项有 54 个 group，每帧线性扫一遍太浪费；而且 render 是逐张牌来问的，
-- 摊平成哈希正好是一次 O(1) 查表。
local function indexGroups(it)
  local map = {}
  for _, g in ipairs(it.groups or {}) do
    local colMap = map[g.col]
    if not colMap then colMap = {}; map[g.col] = colMap end
    for k = g.first, g.first + (g.count or 1) - 1 do
      colMap[k] = g
    end
  end
  it._map = map
end

function M.push(q, it)
  -- "reset" 不是一项动画，而是一条【指令】：把队列清空。
  -- 撤销会瞬间把牌放回原位，之前排着的动画全部失去意义。
  if it.kind == "reset" then
    M.clear(q)
    return it
  end

  it.t     = 0
  it.dur   = it.dur or 0.2
  it.total = totalOf(it)
  if it.kind == "shift" then indexGroups(it) end
  q.items[#q.items + 1] = it
  return it
end

-- 推进 dt。返回【这一帧刚刚播完】的那一项（用于调试/日志），没有就 nil。
-- 用 while 而不是 if：掉帧时一帧可能要跨过好几项，否则动画会整体变慢。
function M.update(q, dt)
  local done = nil

  while dt > 0 do
    local it = q.items[1]
    if not it then break end

    local need = it.total - it.t
    if need <= 0 then
      table.remove(q.items, 1)
      done = it
    elseif dt >= need then
      it.t = it.total
      table.remove(q.items, 1)
      done = it
      dt = dt - need
    else
      it.t = it.t + dt
      dt = 0
    end
  end

  return done
end

-- 某一列第 index 张牌上有没有 shift 动画？render 每帧逐张问。
--
-- 返回值：
--   nil               没有动画覆盖 → 按最终位置正常画
--   { hide = true }   这项动画还没轮到这一张（开局发牌时"还没发到"）→ 不要画
--   { dx, dy }        偏移这么多像素再画
--
-- 注意 t == 0 时【不】hide：那一刻牌正好停在起始位置（偏移 = 全量），
-- 让它画在起点比让它消失更自然。避免每次移动都闪一帧。
function M.shiftFor(it, col, index)
  if not it or it.kind ~= "shift" or not it._map then return nil end

  local colMap = it._map[col]
  local g = colMap and colMap[index]
  if not g then return nil end

  local t = it.t - (g.delay or 0)
  if t < 0 then return { hide = true } end

  local p = t / (g.dur or it.dur)
  if p >= 1 then return nil end

  local k = 1 - M.easeOutCubic(p)
  return { dx = (g.dx or 0) * k, dy = (g.dy or 0) * k }
end

-- collect 动画的进度（0..1，已缓动）
function M.collectProgress(it)
  if not it or it.kind ~= "collect" then return nil end
  return M.easeOutCubic(M.clamp01(it.t / it.dur))
end

return M
