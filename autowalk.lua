local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer

local hasFileSystem = (writefile ~= nil and readfile ~= nil and isfile ~= nil)
if not hasFileSystem then
    warn("AutoWalk butuh file system untuk membaca hasil merge.")
    return
end

local hasListFiles = (listfiles ~= nil)
local BRIDGE_FILE = "autowalk_bridge.json"

local REVERSE_MAPPING = {
    ["11"] = "Position",
    ["88"] = "LookVector",
    ["55"] = "UpVector",
    ["22"] = "Velocity",
    ["33"] = "MoveState",
    ["44"] = "WalkSpeed",
    ["66"] = "Timestamp"
}

local Theme = {
    BgTop = Color3.fromRGB(236, 246, 255),
    BgBottom = Color3.fromRGB(223, 232, 255),
    Surface = Color3.fromRGB(250, 252, 255),
    SurfaceAlt = Color3.fromRGB(239, 244, 255),
    SurfaceSoft = Color3.fromRGB(228, 236, 250),
    Border = Color3.fromRGB(187, 198, 219),
    BorderStrong = Color3.fromRGB(99, 102, 241),
    Text = Color3.fromRGB(27, 35, 52),
    TextMuted = Color3.fromRGB(98, 108, 132),
    Primary = Color3.fromRGB(59, 130, 246),
    PrimaryDark = Color3.fromRGB(37, 99, 235),
    Green = Color3.fromRGB(34, 197, 94),
    GreenDark = Color3.fromRGB(22, 163, 74),
    Red = Color3.fromRGB(239, 68, 68),
    RedDark = Color3.fromRGB(220, 38, 38),
    Amber = Color3.fromRGB(245, 158, 11),
    AmberDark = Color3.fromRGB(217, 119, 6),
    Slate = Color3.fromRGB(100, 116, 139),
    SlateDark = Color3.fromRGB(71, 85, 105)
}

local state = {
    isPlaying = false,
    playbackSpeed = 1,
    currentIndex = 1,
    startTime = 0,
    connection = nil,
    frames = {},
    recordingName = "-",
    mountainName = "-",
    mergedFile = "",
    ownerUserId = nil,
    ownerName = "-",
    ownerDisplayName = "-",
    bridgeInfo = nil,
    currentPage = "home"
}

local ui = {
    pages = {},
    navButtons = {},
    libraryItems = {}
}

local function SafeCall(func, ...)
    local ok, result = pcall(func, ...)
    if not ok then
        warn("AutoWalk error:", result)
    end
    return ok, result
end

local function Trim(text)
    return tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function Basename(path)
    local match = tostring(path or ""):match("([^\\/]+)$")
    return match or tostring(path or "")
end

local function DeobfuscateRecordingData(obfuscatedData)
    local deobfuscated = {}
    for checkpointName, frames in pairs(obfuscatedData) do
        local outFrames = {}
        for _, frame in ipairs(frames) do
            local parsed = {}
            for code, value in pairs(frame) do
                parsed[REVERSE_MAPPING[code] or code] = value
            end
            table.insert(outFrames, parsed)
        end
        deobfuscated[checkpointName] = outFrames
    end
    return deobfuscated
end

local function GetFrameCFrame(frame)
    local pos = Vector3.new(frame.Position[1], frame.Position[2], frame.Position[3])
    local look = Vector3.new(frame.LookVector[1], frame.LookVector[2], frame.LookVector[3])
    local up = Vector3.new(frame.UpVector[1], frame.UpVector[2], frame.UpVector[3])
    return CFrame.lookAt(pos, pos + look, up)
end

local function SetStatus(text, color)
    if ui.statusChip then
        ui.statusChip.Text = text
        ui.statusChip.TextColor3 = color or Theme.Text
    end
    if ui.homeStatus then
        ui.homeStatus.Text = text
        ui.homeStatus.TextColor3 = color or Theme.Text
    end
end

local function HasOwnerAccess()
    if not state.ownerUserId then
        return true
    end
    return player.UserId == state.ownerUserId
end

local function GetAccessText()
    if HasOwnerAccess() then
        return "AKSES DIIZINKAN", Theme.Green
    end
    return "AKSES DITOLAK", Theme.Red
end

local function StopAutoWalk()
    state.isPlaying = false
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end
    SetStatus("STOPPED", Theme.Red)
end

local function RefreshOverview()
    if ui.heroTitle then
        ui.heroTitle.Text = state.mountainName ~= "-" and state.mountainName or "Belum Ada Merge"
    end
    if ui.heroSub then
        ui.heroSub.Text = "Record: " .. state.recordingName .. " | Frames: " .. tostring(#state.frames)
    end
    if ui.fileValue then
        ui.fileValue.Text = state.mergedFile ~= "" and state.mergedFile or "-"
    end
    if ui.recordValue then
        ui.recordValue.Text = state.recordingName
    end
    if ui.mountainValue then
        ui.mountainValue.Text = state.mountainName
    end
    if ui.framesValue then
        ui.framesValue.Text = tostring(#state.frames)
    end
    if ui.fileBox then
        ui.fileBox.Text = state.mergedFile
    end
    if ui.bridgeInfoLabel then
        if state.bridgeInfo then
            ui.bridgeInfoLabel.Text = "Bridge: " .. (state.bridgeInfo.MergedFile or "-") .. "\nUpdate: " .. (state.bridgeInfo.UpdatedAt or "-")
        else
            ui.bridgeInfoLabel.Text = "Bridge: belum ada"
        end
    end
    if ui.ownerValue then
        ui.ownerValue.Text = state.ownerName ~= "-" and (state.ownerDisplayName .. " (@" .. state.ownerName .. ")") or "-"
    end
    if ui.userValue then
        ui.userValue.Text = player.DisplayName .. " (@" .. player.Name .. ")"
    end
    if ui.ownerIdValue then
        ui.ownerIdValue.Text = state.ownerUserId and tostring(state.ownerUserId) or "-"
    end
    if ui.userIdValue then
        ui.userIdValue.Text = tostring(player.UserId)
    end
    if ui.accessValue then
        local accessText, accessColor = GetAccessText()
        ui.accessValue.Text = accessText
        ui.accessValue.TextColor3 = accessColor
    end
end

local function CreateRounded(instance, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = instance
    return corner
end

local function CreateStroke(instance, color, transparency, thickness)
    local stroke = Instance.new("UIStroke")
    stroke.Color = color
    stroke.Transparency = transparency or 0
    stroke.Thickness = thickness or 1
    stroke.Parent = instance
    return stroke
end

local function CreateButton(parent, text, position, size, color, hoverColor, textColor)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = color
    button.Text = text
    button.TextColor3 = textColor or Color3.new(1, 1, 1)
    button.Font = Enum.Font.GothamBold
    button.TextSize = 12
    button.AutoButtonColor = false
    button.BorderSizePixel = 0
    button.Parent = parent
    CreateRounded(button, 10)
    CreateStroke(button, Color3.new(1, 1, 1), 0.72, 1)

    button.MouseEnter:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = hoverColor}):Play()
    end)

    button.MouseLeave:Connect(function()
        TweenService:Create(button, TweenInfo.new(0.15), {BackgroundColor3 = color}):Play()
    end)

    return button
end

local function CreateCard(parent, position, size)
    local card = Instance.new("Frame")
    card.Position = position
    card.Size = size
    card.BackgroundColor3 = Theme.Surface
    card.BorderSizePixel = 0
    card.Parent = parent
    CreateRounded(card, 16)
    CreateStroke(card, Theme.Border, 0.15, 1)
    return card
end

local function SetCurrentPage(pageName)
    state.currentPage = pageName
    for name, page in pairs(ui.pages) do
        page.Visible = (name == pageName)
    end
    for name, button in pairs(ui.navButtons) do
        local active = (name == pageName)
        button.BackgroundColor3 = active and Theme.Primary or Theme.SurfaceSoft
        button.TextColor3 = active and Color3.new(1, 1, 1) or Theme.Text
    end
end

local function LoadMergeDataFromFile(fileName)
    fileName = Trim(fileName)
    if fileName == "" or not isfile(fileName) then
        SetStatus("FILE NOT FOUND", Theme.Red)
        return false
    end

    local ok, parsed = SafeCall(function()
        return HttpService:JSONDecode(readfile(fileName))
    end)
    if not ok or type(parsed) ~= "table" or not parsed.ObfuscatedFrames then
        SetStatus("INVALID MERGE DATA", Theme.Red)
        return false
    end

    local decoded = DeobfuscateRecordingData(parsed.ObfuscatedFrames)
    local recordingName = parsed.RecordingOrder and parsed.RecordingOrder[1]
    local frames = recordingName and decoded[recordingName] or nil
    if not frames or #frames == 0 then
        SetStatus("FRAMES KOSONG", Theme.Red)
        return false
    end

    local meta = parsed.RecordingMeta and parsed.RecordingMeta[recordingName]
    local display = parsed.CheckpointNames and parsed.CheckpointNames[recordingName]

    state.frames = frames
    state.recordingName = recordingName or "-"
    state.mergedFile = fileName
    state.mountainName = (meta and meta.MountainName) or display or state.recordingName
    state.ownerUserId = meta and meta.OwnerUserId or nil
    state.ownerName = meta and meta.OwnerName or "-"
    state.ownerDisplayName = meta and meta.OwnerDisplayName or state.ownerName

    RefreshOverview()
    SetStatus("READY", Theme.Green)
    return true
end

local function LoadLatestBridge()
    if not isfile(BRIDGE_FILE) then
        state.bridgeInfo = nil
        RefreshOverview()
        SetStatus("BRIDGE BELUM ADA", Theme.Red)
        return false
    end

    local ok, bridge = SafeCall(function()
        return HttpService:JSONDecode(readfile(BRIDGE_FILE))
    end)
    if not ok or type(bridge) ~= "table" then
        state.bridgeInfo = nil
        RefreshOverview()
        SetStatus("BRIDGE RUSAK", Theme.Red)
        return false
    end

    state.bridgeInfo = bridge
    RefreshOverview()
    return LoadMergeDataFromFile(bridge.MergedFile)
end

local function GetMergeFiles()
    if not hasListFiles then
        return {}
    end

    local files = {}
    local ok, list = SafeCall(function()
        return listfiles(".")
    end)
    if not ok or type(list) ~= "table" then
        return files
    end

    for _, fullPath in ipairs(list) do
        local name = Basename(fullPath)
        if name:match("^merged_.*%.json$") then
            table.insert(files, name)
        end
    end

    table.sort(files, function(a, b)
        return a > b
    end)

    return files
end

local function RefreshLibrary()
    if not ui.libraryList then
        return
    end

    for _, child in ipairs(ui.libraryList:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    ui.libraryItems = {}

    local files = GetMergeFiles()
    local y = 0

    if #files == 0 then
        local empty = Instance.new("Frame")
        empty.Size = UDim2.new(1, 0, 0, 56)
        empty.BackgroundColor3 = Theme.SurfaceAlt
        empty.BorderSizePixel = 0
        empty.Parent = ui.libraryList
        CreateRounded(empty, 12)

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -16, 1, 0)
        label.Position = UDim2.fromOffset(8, 0)
        label.BackgroundTransparency = 1
        label.Text = hasListFiles and "Belum ada file merge local." or "Executor ini tidak support listfiles."
        label.TextColor3 = Theme.TextMuted
        label.Font = Enum.Font.Gotham
        label.TextSize = 12
        label.TextWrapped = true
        label.Parent = empty

        ui.libraryList.CanvasSize = UDim2.new(0, 0, 0, 56)
        return
    end

    for _, fileName in ipairs(files) do
        local item = Instance.new("Frame")
        item.Size = UDim2.new(1, 0, 0, 60)
        item.Position = UDim2.new(0, 0, 0, y)
        item.BackgroundColor3 = Theme.SurfaceAlt
        item.BorderSizePixel = 0
        item.Parent = ui.libraryList
        CreateRounded(item, 12)
        CreateStroke(item, Theme.Border, 0.25, 1)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Size = UDim2.new(1, -100, 0, 24)
        nameLabel.Position = UDim2.fromOffset(10, 8)
        nameLabel.BackgroundTransparency = 1
        nameLabel.Text = fileName
        nameLabel.TextColor3 = Theme.Text
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextSize = 12
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = item

        local hintLabel = Instance.new("TextLabel")
        hintLabel.Size = UDim2.new(1, -100, 0, 18)
        hintLabel.Position = UDim2.fromOffset(10, 32)
        hintLabel.BackgroundTransparency = 1
        hintLabel.Text = "Klik Load untuk pakai hasil merge ini"
        hintLabel.TextColor3 = Theme.TextMuted
        hintLabel.Font = Enum.Font.Gotham
        hintLabel.TextSize = 11
        hintLabel.TextXAlignment = Enum.TextXAlignment.Left
        hintLabel.Parent = item

        local loadButton = CreateButton(item, "LOAD", UDim2.new(1, -74, 0, 15), UDim2.fromOffset(64, 30), Theme.Primary, Theme.PrimaryDark)
        loadButton.MouseButton1Click:Connect(function()
            StopAutoWalk()
            LoadMergeDataFromFile(fileName)
            SetCurrentPage("home")
        end)

        y = y + 68
    end

    ui.libraryList.CanvasSize = UDim2.new(0, 0, 0, y)
end

local function PlayAutoWalk()
    if state.isPlaying or #state.frames == 0 then
        return
    end

    if not HasOwnerAccess() then
        SetStatus("OWNER ONLY", Theme.Red)
        return
    end

    local character = player.Character or player.CharacterAdded:Wait()
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local hrp = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not hrp then
        SetStatus("CHARACTER TIDAK SIAP", Theme.Red)
        return
    end

    state.isPlaying = true
    state.currentIndex = 1
    state.startTime = tick()

    hrp.CFrame = GetFrameCFrame(state.frames[1])
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    SetStatus("PLAYING", Theme.Green)

    state.connection = RunService.Heartbeat:Connect(function()
        if not state.isPlaying then
            StopAutoWalk()
            return
        end

        local liveCharacter = player.Character
        if not liveCharacter then
            StopAutoWalk()
            return
        end

        humanoid = liveCharacter:FindFirstChildOfClass("Humanoid")
        hrp = liveCharacter:FindFirstChild("HumanoidRootPart")
        if not humanoid or not hrp then
            StopAutoWalk()
            return
        end

        local effectiveTime = (tick() - state.startTime) * state.playbackSpeed
        while state.currentIndex < #state.frames and (state.frames[state.currentIndex + 1].Timestamp or 0) <= effectiveTime do
            state.currentIndex = state.currentIndex + 1
        end

        local frame = state.frames[state.currentIndex]
        if not frame then
            StopAutoWalk()
            return
        end

        humanoid.AutoRotate = false
        humanoid.WalkSpeed = frame.WalkSpeed or 16
        hrp.CFrame = GetFrameCFrame(frame)
        hrp.AssemblyLinearVelocity = Vector3.new(frame.Velocity[1], frame.Velocity[2], frame.Velocity[3])
        hrp.AssemblyAngularVelocity = Vector3.zero

        if state.currentIndex >= #state.frames then
            StopAutoWalk()
        end
    end)
end

local function CreateUI()
    ui.screenGui = Instance.new("ScreenGui")
    ui.screenGui.Name = "ModernAutoWalk"
    ui.screenGui.ResetOnSpawn = false
    ui.screenGui.Parent = player:WaitForChild("PlayerGui")

    local floating = CreateButton(ui.screenGui, "Hide UI", UDim2.new(0, 18, 0, 16), UDim2.fromOffset(96, 34), Theme.Primary, Theme.PrimaryDark)
    ui.toggleButton = floating
    CreateRounded(floating, 17)

    ui.quickPanel = Instance.new("Frame")
    ui.quickPanel.Size = UDim2.fromOffset(170, 44)
    ui.quickPanel.Position = UDim2.new(0, 122, 0, 12)
    ui.quickPanel.BackgroundColor3 = Theme.Surface
    ui.quickPanel.BorderSizePixel = 0
    ui.quickPanel.Parent = ui.screenGui
    CreateRounded(ui.quickPanel, 20)
    CreateStroke(ui.quickPanel, Theme.BorderStrong, 0.35, 1)

    local quickGradient = Instance.new("UIGradient")
    quickGradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.BgTop),
        ColorSequenceKeypoint.new(1, Theme.BgBottom)
    })
    quickGradient.Rotation = 0
    quickGradient.Parent = ui.quickPanel

    local quickPlay = CreateButton(ui.quickPanel, "PLAY", UDim2.fromOffset(6, 6), UDim2.fromOffset(74, 32), Theme.Green, Theme.GreenDark)
    local quickStop = CreateButton(ui.quickPanel, "STOP", UDim2.fromOffset(88, 6), UDim2.fromOffset(74, 32), Theme.Red, Theme.RedDark)

    ui.mainFrame = Instance.new("Frame")
    ui.mainFrame.Size = UDim2.fromOffset(560, 365)
    ui.mainFrame.Position = UDim2.new(0, 18, 0, 60)
    ui.mainFrame.BackgroundColor3 = Theme.Surface
    ui.mainFrame.BorderSizePixel = 0
    ui.mainFrame.Active = true
    ui.mainFrame.Draggable = true
    ui.mainFrame.Parent = ui.screenGui
    CreateRounded(ui.mainFrame, 24)
    CreateStroke(ui.mainFrame, Theme.BorderStrong, 0.45, 1)

    local backdrop = Instance.new("Frame")
    backdrop.Size = UDim2.new(1, 0, 1, 0)
    backdrop.BackgroundTransparency = 1
    backdrop.Parent = ui.mainFrame

    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.BgTop),
        ColorSequenceKeypoint.new(1, Theme.BgBottom)
    })
    gradient.Rotation = 90
    gradient.Parent = ui.mainFrame

    local leftPanel = Instance.new("Frame")
    leftPanel.Size = UDim2.fromOffset(150, 365)
    leftPanel.BackgroundColor3 = Theme.SurfaceAlt
    leftPanel.BorderSizePixel = 0
    leftPanel.Parent = ui.mainFrame
    CreateRounded(leftPanel, 24)

    local leftFill = Instance.new("Frame")
    leftFill.Size = UDim2.new(0, 24, 1, 0)
    leftFill.Position = UDim2.new(1, -24, 0, 0)
    leftFill.BackgroundColor3 = Theme.SurfaceAlt
    leftFill.BorderSizePixel = 0
    leftFill.Parent = leftPanel

    local brand = Instance.new("TextLabel")
    brand.Size = UDim2.new(1, -24, 0, 50)
    brand.Position = UDim2.fromOffset(16, 18)
    brand.BackgroundTransparency = 1
    brand.Text = "AutoWalk\nStudio"
    brand.TextColor3 = Theme.Text
    brand.Font = Enum.Font.GothamBlack
    brand.TextSize = 18
    brand.TextXAlignment = Enum.TextXAlignment.Left
    brand.TextYAlignment = Enum.TextYAlignment.Top
    brand.Parent = leftPanel

    ui.statusChip = Instance.new("TextLabel")
    ui.statusChip.Size = UDim2.new(1, -32, 0, 28)
    ui.statusChip.Position = UDim2.fromOffset(16, 78)
    ui.statusChip.BackgroundColor3 = Theme.Surface
    ui.statusChip.Text = "READY"
    ui.statusChip.TextColor3 = Theme.Green
    ui.statusChip.Font = Enum.Font.GothamBold
    ui.statusChip.TextSize = 12
    ui.statusChip.BorderSizePixel = 0
    ui.statusChip.Parent = leftPanel
    CreateRounded(ui.statusChip, 14)
    CreateStroke(ui.statusChip, Theme.Border, 0.2, 1)

    local navHolder = Instance.new("Frame")
    navHolder.Size = UDim2.new(1, -20, 0, 126)
    navHolder.Position = UDim2.fromOffset(10, 122)
    navHolder.BackgroundTransparency = 1
    navHolder.Parent = leftPanel

    local navLayout = Instance.new("UIListLayout")
    navLayout.FillDirection = Enum.FillDirection.Vertical
    navLayout.Padding = UDim.new(0, 8)
    navLayout.Parent = navHolder

    local function AddNavButton(id, text)
        local btn = CreateButton(navHolder, text, UDim2.new(), UDim2.new(1, 0, 0, 34), Theme.SurfaceSoft, Theme.Primary, Theme.Text)
        ui.navButtons[id] = btn
        btn.MouseButton1Click:Connect(function()
            SetCurrentPage(id)
        end)
    end

    AddNavButton("home", "Home")
    AddNavButton("library", "Library")
    AddNavButton("profile", "Profile")
    AddNavButton("about", "About")

    local footer = Instance.new("TextLabel")
    footer.Size = UDim2.new(1, -30, 0, 78)
    footer.Position = UDim2.fromOffset(16, 268)
    footer.BackgroundTransparency = 1
    footer.Text = "Bridge lokal dari asik.lua\nRaw GitHub hanya bawa script, bukan file merge lokal."
    footer.TextColor3 = Theme.TextMuted
    footer.Font = Enum.Font.Gotham
    footer.TextSize = 11
    footer.TextWrapped = true
    footer.TextXAlignment = Enum.TextXAlignment.Left
    footer.TextYAlignment = Enum.TextYAlignment.Top
    footer.Parent = leftPanel

    local rightPanel = Instance.new("Frame")
    rightPanel.Size = UDim2.new(1, -166, 1, -16)
    rightPanel.Position = UDim2.fromOffset(158, 8)
    rightPanel.BackgroundTransparency = 1
    rightPanel.Parent = ui.mainFrame

    local function AddPage(id)
        local page = Instance.new("Frame")
        page.Size = UDim2.new(1, 0, 1, 0)
        page.BackgroundTransparency = 1
        page.Visible = false
        page.Parent = rightPanel
        ui.pages[id] = page
        return page
    end

    local homePage = AddPage("home")
    local libraryPage = AddPage("library")
    local profilePage = AddPage("profile")
    local aboutPage = AddPage("about")

    local hero = CreateCard(homePage, UDim2.fromOffset(0, 0), UDim2.fromOffset(386, 126))
    local heroGlow = Instance.new("Frame")
    heroGlow.Size = UDim2.new(1, 0, 1, 0)
    heroGlow.BackgroundColor3 = Theme.Primary
    heroGlow.BackgroundTransparency = 0.92
    heroGlow.BorderSizePixel = 0
    heroGlow.Parent = hero
    CreateRounded(heroGlow, 16)

    ui.heroTitle = Instance.new("TextLabel")
    ui.heroTitle.Size = UDim2.new(1, -24, 0, 32)
    ui.heroTitle.Position = UDim2.fromOffset(16, 14)
    ui.heroTitle.BackgroundTransparency = 1
    ui.heroTitle.Text = "Belum Ada Merge"
    ui.heroTitle.TextColor3 = Theme.Text
    ui.heroTitle.Font = Enum.Font.GothamBlack
    ui.heroTitle.TextSize = 24
    ui.heroTitle.TextXAlignment = Enum.TextXAlignment.Left
    ui.heroTitle.Parent = hero

    ui.heroSub = Instance.new("TextLabel")
    ui.heroSub.Size = UDim2.new(1, -24, 0, 24)
    ui.heroSub.Position = UDim2.fromOffset(16, 52)
    ui.heroSub.BackgroundTransparency = 1
    ui.heroSub.Text = "Record: - | Frames: 0"
    ui.heroSub.TextColor3 = Theme.TextMuted
    ui.heroSub.Font = Enum.Font.GothamMedium
    ui.heroSub.TextSize = 13
    ui.heroSub.TextXAlignment = Enum.TextXAlignment.Left
    ui.heroSub.Parent = hero

    ui.homeStatus = Instance.new("TextLabel")
    ui.homeStatus.Size = UDim2.fromOffset(100, 28)
    ui.homeStatus.Position = UDim2.fromOffset(16, 86)
    ui.homeStatus.BackgroundColor3 = Theme.SurfaceSoft
    ui.homeStatus.Text = "READY"
    ui.homeStatus.TextColor3 = Theme.Green
    ui.homeStatus.Font = Enum.Font.GothamBold
    ui.homeStatus.TextSize = 12
    ui.homeStatus.BorderSizePixel = 0
    ui.homeStatus.Parent = hero
    CreateRounded(ui.homeStatus, 14)

    local loadLatest = CreateButton(hero, "LOAD LATEST", UDim2.fromOffset(204, 82), UDim2.fromOffset(90, 32), Theme.Primary, Theme.PrimaryDark)
    local playBtn = CreateButton(hero, "PLAY", UDim2.fromOffset(300, 82), UDim2.fromOffset(70, 32), Theme.Green, Theme.GreenDark)
    local stopBtn = CreateButton(hero, "STOP", UDim2.fromOffset(300, 82), UDim2.fromOffset(70, 32), Theme.Red, Theme.RedDark)
    stopBtn.Position = UDim2.fromOffset(300, 82)

    local fileCard = CreateCard(homePage, UDim2.fromOffset(0, 138), UDim2.fromOffset(386, 78))
    local fileTitle = Instance.new("TextLabel")
    fileTitle.Size = UDim2.new(1, -20, 0, 18)
    fileTitle.Position = UDim2.fromOffset(12, 10)
    fileTitle.BackgroundTransparency = 1
    fileTitle.Text = "Manual Merge File"
    fileTitle.TextColor3 = Theme.Text
    fileTitle.Font = Enum.Font.GothamBold
    fileTitle.TextSize = 12
    fileTitle.TextXAlignment = Enum.TextXAlignment.Left
    fileTitle.Parent = fileCard

    ui.fileBox = Instance.new("TextBox")
    ui.fileBox.Size = UDim2.new(1, -112, 0, 34)
    ui.fileBox.Position = UDim2.fromOffset(12, 32)
    ui.fileBox.BackgroundColor3 = Theme.SurfaceSoft
    ui.fileBox.BorderSizePixel = 0
    ui.fileBox.PlaceholderText = "merged_namaGunung_123456.json"
    ui.fileBox.Text = ""
    ui.fileBox.TextColor3 = Theme.Text
    ui.fileBox.Font = Enum.Font.Gotham
    ui.fileBox.TextSize = 12
    ui.fileBox.ClearTextOnFocus = false
    ui.fileBox.Parent = fileCard
    CreateRounded(ui.fileBox, 10)

    local loadFileBtn = CreateButton(fileCard, "LOAD", UDim2.new(1, -90, 0, 32), UDim2.fromOffset(78, 34), Theme.Amber, Theme.AmberDark)

    local statsCard = CreateCard(homePage, UDim2.fromOffset(0, 228), UDim2.fromOffset(386, 113))
    local function AddStat(labelText, y, refName)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromOffset(82, 18)
        label.Position = UDim2.fromOffset(14, y)
        label.BackgroundTransparency = 1
        label.Text = labelText
        label.TextColor3 = Theme.TextMuted
        label.Font = Enum.Font.GothamMedium
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = statsCard

        local value = Instance.new("TextLabel")
        value.Size = UDim2.fromOffset(276, 18)
        value.Position = UDim2.fromOffset(96, y)
        value.BackgroundTransparency = 1
        value.Text = "-"
        value.TextColor3 = Theme.Text
        value.Font = Enum.Font.GothamBold
        value.TextSize = 11
        value.TextXAlignment = Enum.TextXAlignment.Left
        value.Parent = statsCard
        ui[refName] = value
    end

    AddStat("Gunung", 14, "mountainValue")
    AddStat("Record", 38, "recordValue")
    AddStat("Frames", 62, "framesValue")
    AddStat("File", 86, "fileValue")

    local libraryHeader = CreateCard(libraryPage, UDim2.fromOffset(0, 0), UDim2.fromOffset(386, 60))
    local libraryTitle = Instance.new("TextLabel")
    libraryTitle.Size = UDim2.new(1, -120, 0, 22)
    libraryTitle.Position = UDim2.fromOffset(14, 10)
    libraryTitle.BackgroundTransparency = 1
    libraryTitle.Text = "Library Merge Lokal"
    libraryTitle.TextColor3 = Theme.Text
    libraryTitle.Font = Enum.Font.GothamBlack
    libraryTitle.TextSize = 18
    libraryTitle.TextXAlignment = Enum.TextXAlignment.Left
    libraryTitle.Parent = libraryHeader

    local librarySub = Instance.new("TextLabel")
    librarySub.Size = UDim2.new(1, -120, 0, 16)
    librarySub.Position = UDim2.fromOffset(14, 34)
    librarySub.BackgroundTransparency = 1
    librarySub.Text = "Menampilkan file merge hasil dari asik.lua"
    librarySub.TextColor3 = Theme.TextMuted
    librarySub.Font = Enum.Font.Gotham
    librarySub.TextSize = 11
    librarySub.TextXAlignment = Enum.TextXAlignment.Left
    librarySub.Parent = libraryHeader

    local refreshLibraryBtn = CreateButton(libraryHeader, "REFRESH", UDim2.new(1, -94, 0, 14), UDim2.fromOffset(80, 30), Theme.Primary, Theme.PrimaryDark)

    local libraryCard = CreateCard(libraryPage, UDim2.fromOffset(0, 72), UDim2.fromOffset(386, 269))
    ui.libraryList = Instance.new("ScrollingFrame")
    ui.libraryList.Size = UDim2.new(1, -14, 1, -14)
    ui.libraryList.Position = UDim2.fromOffset(7, 7)
    ui.libraryList.BackgroundTransparency = 1
    ui.libraryList.BorderSizePixel = 0
    ui.libraryList.ScrollBarThickness = 4
    ui.libraryList.CanvasSize = UDim2.new(0, 0, 0, 0)
    ui.libraryList.Parent = libraryCard

    local profileTop = CreateCard(profilePage, UDim2.fromOffset(0, 0), UDim2.fromOffset(386, 84))
    local profileTitle = Instance.new("TextLabel")
    profileTitle.Size = UDim2.new(1, -20, 0, 24)
    profileTitle.Position = UDim2.fromOffset(14, 12)
    profileTitle.BackgroundTransparency = 1
    profileTitle.Text = "Profile & Owner Lock"
    profileTitle.TextColor3 = Theme.Text
    profileTitle.Font = Enum.Font.GothamBlack
    profileTitle.TextSize = 18
    profileTitle.TextXAlignment = Enum.TextXAlignment.Left
    profileTitle.Parent = profileTop

    local profileSub = Instance.new("TextLabel")
    profileSub.Size = UDim2.new(1, -20, 0, 34)
    profileSub.Position = UDim2.fromOffset(14, 40)
    profileSub.BackgroundTransparency = 1
    profileSub.Text = "File merge hasil record hanya bisa dipakai owner yang membuat merge."
    profileSub.TextColor3 = Theme.TextMuted
    profileSub.Font = Enum.Font.Gotham
    profileSub.TextSize = 11
    profileSub.TextWrapped = true
    profileSub.TextXAlignment = Enum.TextXAlignment.Left
    profileSub.TextYAlignment = Enum.TextYAlignment.Top
    profileSub.Parent = profileTop

    local profileCard = CreateCard(profilePage, UDim2.fromOffset(0, 96), UDim2.fromOffset(386, 166))
    local function AddProfileRow(labelText, y, refName)
        local label = Instance.new("TextLabel")
        label.Size = UDim2.fromOffset(92, 18)
        label.Position = UDim2.fromOffset(14, y)
        label.BackgroundTransparency = 1
        label.Text = labelText
        label.TextColor3 = Theme.TextMuted
        label.Font = Enum.Font.GothamMedium
        label.TextSize = 11
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = profileCard

        local value = Instance.new("TextLabel")
        value.Size = UDim2.fromOffset(258, 18)
        value.Position = UDim2.fromOffset(114, y)
        value.BackgroundTransparency = 1
        value.Text = "-"
        value.TextColor3 = Theme.Text
        value.Font = Enum.Font.GothamBold
        value.TextSize = 11
        value.TextXAlignment = Enum.TextXAlignment.Left
        value.Parent = profileCard
        ui[refName] = value
    end

    AddProfileRow("Owner", 16, "ownerValue")
    AddProfileRow("Owner UserId", 42, "ownerIdValue")
    AddProfileRow("Kamu", 68, "userValue")
    AddProfileRow("UserId Kamu", 94, "userIdValue")
    AddProfileRow("Akses", 120, "accessValue")

    local profileNote = CreateCard(profilePage, UDim2.fromOffset(0, 274), UDim2.fromOffset(386, 67))
    local profileNoteText = Instance.new("TextLabel")
    profileNoteText.Size = UDim2.new(1, -24, 1, -20)
    profileNoteText.Position = UDim2.fromOffset(12, 10)
    profileNoteText.BackgroundTransparency = 1
    profileNoteText.Text = "Kalau owner berbeda dengan akun yang sedang memakai autowalk, tombol PLAY akan diblok."
    profileNoteText.TextColor3 = Theme.Text
    profileNoteText.Font = Enum.Font.Gotham
    profileNoteText.TextSize = 12
    profileNoteText.TextWrapped = true
    profileNoteText.TextXAlignment = Enum.TextXAlignment.Left
    profileNoteText.TextYAlignment = Enum.TextYAlignment.Top
    profileNoteText.Parent = profileNote

    local aboutTop = CreateCard(aboutPage, UDim2.fromOffset(0, 0), UDim2.fromOffset(386, 114))
    local aboutTitle = Instance.new("TextLabel")
    aboutTitle.Size = UDim2.new(1, -20, 0, 24)
    aboutTitle.Position = UDim2.fromOffset(14, 12)
    aboutTitle.BackgroundTransparency = 1
    aboutTitle.Text = "Koneksi Dengan asik.lua"
    aboutTitle.TextColor3 = Theme.Text
    aboutTitle.Font = Enum.Font.GothamBlack
    aboutTitle.TextSize = 18
    aboutTitle.TextXAlignment = Enum.TextXAlignment.Left
    aboutTitle.Parent = aboutTop

    ui.bridgeInfoLabel = Instance.new("TextLabel")
    ui.bridgeInfoLabel.Size = UDim2.new(1, -24, 0, 60)
    ui.bridgeInfoLabel.Position = UDim2.fromOffset(14, 42)
    ui.bridgeInfoLabel.BackgroundTransparency = 1
    ui.bridgeInfoLabel.Text = "Bridge: belum ada"
    ui.bridgeInfoLabel.TextColor3 = Theme.TextMuted
    ui.bridgeInfoLabel.Font = Enum.Font.Gotham
    ui.bridgeInfoLabel.TextSize = 12
    ui.bridgeInfoLabel.TextWrapped = true
    ui.bridgeInfoLabel.TextXAlignment = Enum.TextXAlignment.Left
    ui.bridgeInfoLabel.TextYAlignment = Enum.TextYAlignment.Top
    ui.bridgeInfoLabel.Parent = aboutTop

    local aboutBottom = CreateCard(aboutPage, UDim2.fromOffset(0, 126), UDim2.fromOffset(386, 215))
    local aboutText = Instance.new("TextLabel")
    aboutText.Size = UDim2.new(1, -24, 1, -24)
    aboutText.Position = UDim2.fromOffset(12, 12)
    aboutText.BackgroundTransparency = 1
    aboutText.Text = "Alur lokal sekarang:\n1. asik.lua record lalu merge\n2. metadata owner ikut disimpan ke merged_*.json\n3. asik.lua update autowalk_bridge.json\n4. autowalk.lua baca bridge itu lewat LOAD LATEST\n5. autowalk cek apakah user yang buka sama dengan owner merge\n\nKalau owner berbeda, file tetap bisa terbaca tapi PLAY akan ditolak."
    aboutText.TextColor3 = Theme.Text
    aboutText.Font = Enum.Font.Gotham
    aboutText.TextSize = 12
    aboutText.TextWrapped = true
    aboutText.TextXAlignment = Enum.TextXAlignment.Left
    aboutText.TextYAlignment = Enum.TextYAlignment.Top
    aboutText.Parent = aboutBottom

    floating.MouseButton1Click:Connect(function()
        ui.mainFrame.Visible = not ui.mainFrame.Visible
        floating.Text = ui.mainFrame.Visible and "Hide UI" or "Show UI"
    end)

    loadLatest.MouseButton1Click:Connect(function()
        StopAutoWalk()
        LoadLatestBridge()
        RefreshLibrary()
    end)

    loadFileBtn.MouseButton1Click:Connect(function()
        StopAutoWalk()
        LoadMergeDataFromFile(ui.fileBox.Text)
    end)

    playBtn.MouseButton1Click:Connect(function()
        PlayAutoWalk()
    end)

    stopBtn.MouseButton1Click:Connect(function()
        StopAutoWalk()
    end)

    quickPlay.MouseButton1Click:Connect(function()
        PlayAutoWalk()
    end)

    quickStop.MouseButton1Click:Connect(function()
        StopAutoWalk()
    end)

    refreshLibraryBtn.MouseButton1Click:Connect(function()
        RefreshLibrary()
    end)

end

CreateUI()
RefreshOverview()
RefreshLibrary()
SetCurrentPage("home")
LoadLatestBridge()
