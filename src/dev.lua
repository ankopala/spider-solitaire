-- src/dev.lua —— 开发调试用的假结算数据（纯逻辑，不引用 love）
--
-- 只在 SPIDER_DEV=1 时被用到。ctx.dev 由 main.lua 读环境变量后注入，
-- 本模块【不读环境变量】—— 状态层一旦自己去读，终端测试就会跟着 shell 环境变。
--
-- 三档分别覆盖结算屏 text.stats 的不同分支，见下面每一项的注释。

local M = {}

local VARIANTS = {
  -- 1 普通：best>0 且 games>0 且没破纪录 → stats_both（暗色）
  { name = "normal",   best = 1240,  wins = 8,   games = 12  },
  -- 2 破纪录：同数字 + 高亮 → stats_new（最长的那一档正常数据）
  { name = "new best", best = 1240,  wins = 8,   games = 12,  isNewBest = true },
  -- 3 极端长：纯宽度压力测试（面板 600px，实测约 308px，不会溢出）
  { name = "extreme",  best = 99999, wins = 999, games = 999 },
}

M.count = #VARIANTS

-- 当前档位（1..count）。ctx.devVariant 是唯一权威，跨状态保留 ——
-- playing 里按 J 造局、won 里按 J 换档，只有 ctx 是两边共享的。
-- 非 dev 模式下 ctx.devVariant 压根不存在，这里也不写它。
function M.index(ctx)
  local i = tonumber(ctx and ctx.devVariant) or 1
  if i < 1 or i > M.count then i = 1 end
  return i
end

-- 进到下一档（循环），返回新下标方便调用方打印
function M.next(ctx)
  local i = M.index(ctx) % M.count + 1
  ctx.devVariant = i
  return i
end

-- 取当前档。返回【新表】：绝不能把 VARIANTS 里的表直接交出去 ——
-- 界面层一旦就地改字段，三档数据会一起被污染。
function M.variant(ctx)
  local i = M.index(ctx)
  local v = VARIANTS[i]

  -- 和 persist.statsFor 同一个取整公式（那里是 math.floor(wins*100/games+0.5)）。
  -- 硬编码 pct 的话，以后改 wins/games 忘了改它，界面就会显示
  -- "won 8/12 (66%)" 这种自曝式 bug。
  local pct = 0
  if v.games > 0 then pct = math.floor(v.wins * 100 / v.games + 0.5) end

  return {
    index     = i,
    name      = v.name,
    best      = v.best,
    wins      = v.wins,
    games     = v.games,
    pct       = pct,
    isNewBest = v.isNewBest == true,   -- 缺省时是 nil，转成 false 更好判断
  }
end

return M
