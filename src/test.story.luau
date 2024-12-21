local LogService = game:GetService("LogService")

local AnsiHelper = require(script.Parent.AnsiHelper)

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

local function throttle(fn: () -> (), delay: number): () -> ()
	local lastCall = 0
	local scheduled = false

	local function throttled(...)
		local args = table.pack(...)

		if not scheduled then
			scheduled = true

			task.defer(function()
				local now = tick()
				if now - lastCall < delay then
					task.wait(delay - (now - lastCall))
				end

				fn(table.unpack(args))
				lastCall = tick()

				scheduled = false
			end)
		end
	end

	return throttled
end

return function(target: Frame)
	local container
	local conn

	local function cleanup()
		if container then
			container:Destroy()
		end
		if conn then
			conn:Disconnect()
		end
	end

	local renderOutputOk, renderOutputErr = pcall(function()
		container = Instance.new("Frame")
		container.Size = UDim2.fromScale(0.7, 0.98)
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
		faux.TextTransparency = 0.75
		faux.TextColor3 = Color3.fromRGB(127, 127, 127)
		faux.TextEditable = false
		faux.ClearTextOnFocus = false
		faux.Parent = frame

		local output = ""
		local currentState = AnsiHelper.defaultState()

		TextLabel:GetPropertyChangedSignal("ContentText"):Connect(function()
			faux.Text = TextLabel.ContentText
			faux.Size = UDim2.fromOffset(TextLabel.AbsoluteSize.X, TextLabel.AbsoluteSize.Y)
		end)

		local messageQueue = {}

		local function render()
			local msg = ""
			for _, item in messageQueue do
				msg ..= colorMessageByType(item.message, item.messageType) .. "\n"
			end
			messageQueue = {}

			local wasAtBottom = frame.CanvasPosition.Y >= frame.AbsoluteCanvasSize.Y - frame.AbsoluteSize.Y - 16
			local renderOk, renderErr = pcall(function()
				local segment, newState = AnsiHelper.ansiToRichTextChunk(msg, currentState)
				currentState = newState

				local displayText = segment .. AnsiHelper.getTemporaryClosingString(currentState)
				TextLabel.Text = output .. displayText
				faux.Text = TextLabel.ContentText

				output ..= segment

				if wasAtBottom then
					frame.CanvasPosition = Vector2.new(0, frame.AbsoluteCanvasSize.Y)
				end
			end)

			if not renderOk then
				conn:Disconnect()
				warn("Error rendering message:", renderErr)
			end
		end

		local renderThrottled = throttle(render, 0.01)

		conn = LogService.MessageOut:Connect(function(message, messageType)
			table.insert(messageQueue, { message = message, messageType = messageType })
			renderThrottled()
		end)
	end)

	if not renderOutputOk then
		warn(renderOutputErr)
		return cleanup
	end

	task.spawn(function()
		local runJestTests = require(script.Parent.runJestTests)
		runJestTests()
	end)

	return cleanup
end
