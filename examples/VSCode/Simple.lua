local color = require("color")


return {
    name = "test_theme",
    type = "dark",
    semanticHighlighting = true,
    colors = {
        ["test.scope"] = color.new(180, 0.1, 0.9),
        ["test.scope2"] = "#FF00AA"
    },
    tokenColors = {
        {
            scope = {"arrscope1.yeah", "arrscope2.test"},
            foreground = color.new(65, 0.5, 0.5),
            background = color.new(90, 0.9, 0.9),
            fontStyle = "bold",
        },
        {
            scope = "nonarrscope.help",
            foreground = color.new(65, 0.5, 0.5),
            background = "#FA018B",
            fontStyle = "bold",
        },
    },
    semanticTokenColors = {
        OperatorNew = "#AAFF00"
    },
}