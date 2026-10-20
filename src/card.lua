-- src/card.lua —— 卡牌的纯逻辑：构造 + 显示辅助
--
-- 【重要】本文件不引用 love，可被独立 Lua 解释器加载（与 src/deck.lua 同规则）。
-- rank 用数值 1..13（A=1, J=11, Q=12, K=13），便于比较大小。

local M = {}

M.SUITS = { "spades", "hearts", "diamonds", "clubs" }

M.RANK_TEXT = {
  "A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K",
}

M.SUIT_GLYPH = {
  spades   = "♠",
  hearts   = "♥",
  diamonds = "♦",
  clubs    = "♣",
}

-- 红色花色（渲染时决定用红字还是黑字）
local RED = { hearts = true, diamonds = true }

-- 构造一张牌
function M.new(suit, rank, faceUp)
  return { suit = suit, rank = rank, faceUp = faceUp or false }
end

function M.rankText(rank)
  return M.RANK_TEXT[rank] or "?"
end

function M.suitGlyph(suit)
  return M.SUIT_GLYPH[suit] or "?"
end

function M.isRed(suit)
  return RED[suit] == true
end

-- "K♠" 这样的显示文本
function M.label(c)
  return M.rankText(c.rank) .. M.suitGlyph(c.suit)
end

return M
