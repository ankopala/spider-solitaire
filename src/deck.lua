-- src/deck.lua —— 发牌纯逻辑（M1）
--
-- 【重要】本文件不引用 love，也不做随机数种子设置。
-- 随机源通过参数注入（rng）：游戏内传 love.math.random，
-- 终端测试传 math.random —— 同一份代码两处都能跑。
--
-- 兼容红线：只用 Lua 5.1 与 5.5 都有的写法。
-- 禁用 // 整除、位运算符、table.unpack、goto、unpack、math.pow 等。

local card = require("src.card")

local M = {}

-- 难度 -> 花色复制计划（copies 合计恒为 8，即 8 组共 104 张）
function M.suitPlan(difficulty)
  if difficulty == 1 then
    -- 1 花色：仅黑桃 8 组
    return { { suit = "spades", copies = 8 } }
  elseif difficulty == 2 then
    -- 2 花色：黑桃 + 红桃 各 4 组
    return {
      { suit = "spades", copies = 4 },
      { suit = "hearts", copies = 4 },
    }
  elseif difficulty == 4 then
    -- 4 花色：四种各 2 组
    return {
      { suit = "spades",   copies = 2 },
      { suit = "hearts",   copies = 2 },
      { suit = "diamonds", copies = 2 },
      { suit = "clubs",    copies = 2 },
    }
  end
  error("difficulty 只能是 1 / 2 / 4，收到：" .. tostring(difficulty))
end

-- 生成 104 张未洗牌的牌堆
-- card = { suit = 字符串, rank = 1..13 (A=1, J=11, Q=12, K=13), faceUp = false }
function M.buildDeck(difficulty)
  local cards = {}
  for _, entry in ipairs(M.suitPlan(difficulty)) do
    for _ = 1, entry.copies do
      for rank = 1, 13 do
        cards[#cards + 1] = card.new(entry.suit, rank)
      end
    end
  end
  return cards
end

-- Fisher-Yates 洗牌：从尾到头，每次与 [1, i] 中的随机位置交换（无偏）
-- rng(n) 需返回 [1, n] 的整数
function M.shuffle(cards, rng)
  -- ⚠ 不给默认值。以前这里是 `rng = rng or math.random`，看起来无害，
  -- 但那是复现性的暗门：谁哪天漏传 rng，牌局就悄悄变成不可复现，
  -- 而"同种子同一局"会静默失效。宁可当场报错。
  if type(rng) ~= "function" then
    error("deck.shuffle 需要注入 rng（纯逻辑不得使用 math.random）", 2)
  end
  for i = #cards, 2, -1 do
    local j = rng(i)
    cards[i], cards[j] = cards[j], cards[i]
  end
  return cards
end

-- 完整发一局：建堆 -> 洗牌 -> 发 54 张到 10 列 -> 余 50 张为 stock
function M.dealNewGame(difficulty, rng)
  local deck = M.shuffle(M.buildDeck(difficulty), rng)

  local tableau = {}
  for col = 1, 10 do
    tableau[col] = {}                       -- 10 列全部先建成空表，避免 # 遇 nil 出错
  end

  for col = 1, 10 do
    local count = (col <= 4) and 6 or 5     -- 前 4 列各 6 张，后 6 列各 5 张
    for _ = 1, count do
      tableau[col][#tableau[col] + 1] = table.remove(deck)   -- 从牌堆尾部取
    end
    tableau[col][#tableau[col]].faceUp = true                -- 仅每列顶牌翻开
  end

  return {
    tableau     = tableau,
    stock       = deck,                     -- 此时正好剩 50 张
    foundations = { spades = 0, hearts = 0, diamonds = 0, clubs = 0 },
    difficulty  = difficulty,
  }
end

return M
