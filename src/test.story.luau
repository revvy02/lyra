local LogService = game:GetService("LogService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- Maps Chalk/Jest ANSI color codes to Roblox color strings.
local ANSI_COLOR_MAP = {
	-- Reset (default foreground)
	["[39m"] = "</font>",

	["[30m"] = "rgb(0,0,0)", -- Black
	["[31m"] = "rgb(254, 91, 86)", -- Red
	["[32m"] = "rgb(89, 246, 141)", -- Green
	["[33m"] = "rgb(255, 255, 164)", -- Yellow
	["[34m"] = "rgb(87, 199, 255)", -- Blue
	["[35m"] = "rgb(254, 105, 192)", -- Magenta
	["[36m"] = "rgb(153, 236, 254)", -- Cyan
	["[37m"] = "rgb(240, 240, 239)", -- White
}

local DIM_COLOR = "rgb(140, 141, 143)"

local MESSAGE_TYPE_COLORS = {
	[Enum.MessageType.MessageInfo] = "rgb(0, 139, 219)", -- blue
	[Enum.MessageType.MessageWarning] = "rgb(255, 115, 21)", -- orange
	[Enum.MessageType.MessageError] = "rgb(255,0,0)", -- red
}

local function colorMessageByType(message: string, messageType: Enum.MessageType): string
	local color = MESSAGE_TYPE_COLORS[messageType]
	if color then
		return `<font color="{color}">{message}</font>`
	end
	return message
end

local function jestToRichText(input: string): string
	local output = input

	-- Remove null and ESC characters
	output = output:gsub("%z", ""):gsub("\27", "")

	-- Convert Jest symbols to more readable ones
	output = output:gsub("✓", "✓")
	output = output:gsub("○", "○")
	output = output:gsub("✕", "×")

	-- Handle bold text: [1m ... [22m
	output = output:gsub("%[1m(.-)%[22m", "<b>%1</b>")

	-- Handle dim text: [2m ... [22m
	output = output:gsub("%[2m(.-)%[22m", function(text)
		return string.format('<font color="%s">%s</font>', DIM_COLOR, text)
	end)

	-- Handle underline: [4m ... [24m
	-- Chalk might use underline for emphasis in some cases.
	output = output:gsub("%[4m(.-)%[24m", "<u>%1</u>")

	-- Now replace color codes with <font> tags or close </font>.
	-- Since ANSI_COLOR_MAP only includes recognized codes, unrecognized codes will be removed later.
	for code, color in ANSI_COLOR_MAP do
		if color == "</font>" then
			-- This is our "reset" code
			output = output:gsub(code:gsub("%[", "%%["), color)
		else
			output = output:gsub(code:gsub("%[", "%%["), string.format('<font color="%s">', color))
		end
	end

	-- Remove any other unhandled ANSI codes (e.g., [7m for inverse, etc.)
	output = output:gsub("%[[%d;]*m", "")

	-- Make sure all <font> and <b> tags get properly closed
	local openFontTags = 0
	for _ in output:gmatch("<font") do
		openFontTags += 1
	end
	for _ in output:gmatch("</font>") do
		openFontTags -= 1
	end

	local openBoldTags = 0
	for _ in output:gmatch("<b>") do
		openBoldTags += 1
	end
	for _ in output:gmatch("</b>") do
		openBoldTags -= 1
	end

	-- If we ended up with a mismatch, close them out
	while openFontTags > 0 do
		output ..= "</font>"
		openFontTags -= 1
	end
	while openBoldTags > 0 do
		output ..= "</b>"
		openBoldTags -= 1
	end

	return output
end

return function(target: Frame)
	local container
	local conn

	local ok, err = pcall(function()
		container = Instance.new("Frame")
		container.Size = UDim2.fromScale(0.6, 0.9)
		container.Position = UDim2.fromScale(0.5, 0.5)
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
		container.BorderSizePixel = 0
		container.Parent = target

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 16)
		corner.Parent = container

		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 16)
		pad.PaddingRight = UDim.new(0, 16)
		pad.PaddingBottom = UDim.new(0, 16)
		pad.PaddingLeft = UDim.new(0, 16)
		pad.Parent = container

		local frame = Instance.new("ScrollingFrame")
		frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		frame.Size = UDim2.fromScale(1, 1)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.CanvasSize = UDim2.fromScale(0, 0)
		frame.BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
		frame.TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
		frame.ScrollBarThickness = 8
		frame.ScrollBarImageTransparency = 0.5
		frame.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
		frame.Parent = container

		local TextLabel = Instance.new("TextLabel")
		TextLabel.Size = UDim2.fromScale(0.95, 1)
		TextLabel.AutomaticSize = Enum.AutomaticSize.Y
		TextLabel.Position = UDim2.fromScale(0.5, 0)
		TextLabel.AnchorPoint = Vector2.new(0.5, 0)
		TextLabel.BackgroundTransparency = 1
		TextLabel.RichText = true
		TextLabel.TextYAlignment = Enum.TextYAlignment.Bottom
		TextLabel.TextXAlignment = Enum.TextXAlignment.Left
		TextLabel.Text = ""
		TextLabel.TextSize = 16
		TextLabel.TextWrapped = true
		TextLabel.ZIndex = 2
		TextLabel.FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json")

		-- Set the default text color explicitly (Chalk defaults to white if no color code is applied)
		TextLabel.TextColor3 = Color3.fromRGB(240, 240, 239)
		TextLabel.Parent = frame

		local faux = Instance.new("TextBox")
		for _, v in
			{
				"Size",
				"Position",
				"AnchorPoint",
				"BackgroundTransparency",
				"TextXAlignment",
				"TextYAlignment",
				"TextSize",
				"FontFace",
				"TextWrapped",
			}
		do
			faux[v] = TextLabel[v]
		end
		faux.TextTransparency = 0.5
		faux.TextColor3 = Color3.fromRGB(0, 0, 0)
		faux.TextEditable = false
		faux.ClearTextOnFocus = false
		faux.Parent = frame

		TextLabel:GetPropertyChangedSignal("ContentText"):Connect(function()
			faux.Text = TextLabel.ContentText
			faux.Size = UDim2.fromOffset(TextLabel.AbsoluteSize.X, TextLabel.AbsoluteSize.Y)
		end)

		local output = ""

		conn = LogService.MessageOut:Connect(function(message, messageType)
			pcall(function()
				output ..= colorMessageByType(message, messageType) .. "\n"
				TextLabel.Text = jestToRichText(output)
				frame.CanvasPosition = Vector2.new(0, frame.AbsoluteCanvasSize.Y)
			end)
		end)

		-- Example: running Jest's CLI in Roblox
		local runCLI = require(ReplicatedStorage.DevPackages.Jest).runCLI
		local processServiceExists, ProcessService = pcall(function()
			return (game :: any):GetService("ProcessService")
		end)

		local status, result = runCLI(ReplicatedStorage.Packages.Lyra, {
			verbose = true,
			ci = false,
		}, { ReplicatedStorage.Packages.Lyra }):awaitStatus()

		if status == "Rejected" then
			warn(result)
		end

		if status == "Resolved" and result.results.numFailedTestSuites == 0 and result.results.numFailedTests == 0 then
			if processServiceExists then
				ProcessService:ExitAsync(0)
			end
		end

		if processServiceExists then
			ProcessService:ExitAsync(1)
		end
	end)

	if not ok then
		warn(err)
	end

	return function()
		if container then
			container:Destroy()
		end
		if conn then
			conn:Disconnect()
		end
	end
end
