local color = require("color")

local colors = {}
local tokenColors = {}
local semanticTokenColors = {}

local bg_clr = color.new("#161616")
local bg_clr_li = bg_clr:lighten_by(25)

colors["editor.background"] = bg_clr
colors["editor.foreground"] = "#FFFFFF"

return {
    name = "Dark Grey",
    type = "Dark",
    semanticHighlighting = true,
    colors = colors,
    tokenColors = tokenColors,
    semanticTokenColors = semanticTokenColors,
}