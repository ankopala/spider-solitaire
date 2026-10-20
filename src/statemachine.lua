-- src/statemachine.lua —— 字符串状态 + 派发表（纯逻辑，不引用 love）
--
-- 为什么不用对象继承 / 场景图？
--   这个游戏的界面只有 4 屏，用「名字 -> 一个表」的派发表最直接：
--     · 加一屏 = 往表里多放一项，不改任何分支；
--     · 状态表里没有某个回调（比如 menu 没有 update）就自动跳过，不用写空函数；
--     · 纯逻辑，可以在终端用普通 Lua 测试切换顺序（见 tests/states_smoke.lua）。
--
-- 生命周期约定：
--   enter(...)      进入时调用，参数由 setState 原样传进来（例如胜利摘要）
--   leave(nextName) 离开时调用，参数是【要去】的状态名（便于做"离开时保存"）
--   update / draw / mousepressed / mousemoved / mousereleased / keypressed 都可选
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。

local M = {}

local SM = {}
SM.__index = SM

-- states: { menu = {...}, settings = {...}, ... }
-- ctx:    共享上下文（settings / rng / quit / sm 自身），由 main.lua 构造
function M.new(states, ctx)
  return setmetatable({
    states = states or {},
    ctx    = ctx or {},
    name   = nil,          -- 还没进入任何状态时是 nil
  }, SM)
end

-- 切换状态：先让旧状态 leave，再记录名字，最后让新状态 enter。
-- 顺序不能反 —— 否则 leave 里读 sm.name 会读到新状态。
function SM:set(name, ...)
  local nxt = self.states[name]
  if not nxt then
    error(string.format("statemachine: unknown state '%s'", tostring(name)), 2)
  end

  local prev = self.name and self.states[self.name]
  if prev and prev.leave then prev:leave(name) end

  self.name = name

  if nxt.enter then nxt:enter(...) end
  return nxt
end

function SM:current()
  return self.name and self.states[self.name] or nil
end

function SM:is(name)
  return self.name == name
end

-- 转发：当前状态没实现这个方法就静默跳过
local function forward(sm, method, ...)
  local s = sm:current()
  if not s then return nil end
  local fn = s[method]
  if not fn then return nil end
  return fn(s, ...)
end

function SM:update(dt)              return forward(self, "update", dt) end
function SM:draw(ui)                return forward(self, "draw", ui) end
function SM:mousepressed(x, y, b)   return forward(self, "mousepressed", x, y, b) end
function SM:mousemoved(x, y)        return forward(self, "mousemoved", x, y) end
function SM:mousereleased(x, y, b)  return forward(self, "mousereleased", x, y, b) end
function SM:keypressed(k)           return forward(self, "keypressed", k) end

return M
