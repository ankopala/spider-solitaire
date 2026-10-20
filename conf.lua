-- conf.lua —— LÖVE 启动时最先加载，只用来设置窗口与模块开关
-- 注意：此时 love.graphics 还没初始化，不能在这里绘制任何东西。
-- 修改本文件后必须重启程序才会生效。

function love.conf(t)
  t.identity = "spider"   -- 存档目录名（将来存分数 / 设置用）
  t.version  = "11.5"     -- 目标 LÖVE 版本
  t.console  = false      -- 仅 Windows 有效；macOS 想看 print 必须在终端运行 love

  t.window.title     = "蜘蛛纸牌 Spider Solitaire"
  t.window.width     = 1280
  t.window.height    = 720
  t.window.resizable = true
  t.window.vsync     = 1
  t.window.minwidth  = 640
  t.window.minheight = 360
end
