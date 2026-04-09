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
local REGISTRY_FILE = "autowalk_registry.json"
local UI_STATE_FILE = "autowalk_ui_state.json"
local PLAYBACK_FIXED_TIMESTEP = 1 / 60
local JUMP_VELOCITY_THRESHOLD = 10
local STATE_CHANGE_COOLDOWN = 0.08

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
    pausedTime = 0,
    pausedIndex = 1,
    connection = nil,
    playbackAccumulator = 0,
    lastPlaybackState = nil,
    lastStateChangeTime = 0,
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

local loadingUi = {}
local CreateRounded
local CreateStroke

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

local function ReadJsonFile(fileName)
    if not fileName or not isfile(fileName) then
        return nil
    end

    local ok, parsed = SafeCall(function()
        return HttpService:JSONDecode(readfile(fileName))
    end)
    if ok and type(parsed) == "table" then
        return parsed
    end
    return nil
end

local function WriteJsonFile(fileName, data)
    if not fileName or type(data) ~= "table" then
        return false
    end

    local ok = SafeCall(function()
        writefile(fileName, HttpService:JSONEncode(data))
    end)
    return ok
end

local function PositionToTable(position)
    return {
        XScale = position.X.Scale,
        XOffset = position.X.Offset,
        YScale = position.Y.Scale,
        YOffset = position.Y.Offset
    }
end

local function TableToPosition(data, fallback)
    if type(data) ~= "table" then
        return fallback
    end

    return UDim2.new(
        tonumber(data.XScale) or fallback.X.Scale,
        tonumber(data.XOffset) or fallback.X.Offset,
        tonumber(data.YScale) or fallback.Y.Scale,
        tonumber(data.YOffset) or fallback.Y.Offset
    )
end

local function GetRegistryItems()
    local registry = ReadJsonFile(REGISTRY_FILE)
    if registry and type(registry.Items) == "table" then
        return registry.Items
    end
    return {}
end

local function GetLibraryEntries()
    local entries = {}
    local seen = {}

    for _, item in ipairs(GetRegistryItems()) do
        if type(item) == "table" and item.MergedFile and isfile(item.MergedFile) and not seen[item.MergedFile] then
            seen[item.MergedFile] = true
            table.insert(entries, item)
        end
    end

    if #entries == 0 and hasListFiles then
        local ok, list = SafeCall(function()
            return listfiles(".")
        end)
        if ok and type(list) == "table" then
            for _, fullPath in ipairs(list) do
                local name = Basename(fullPath)
                if name:match("^merged_.*%.json$") and not seen[name] then
                    seen[name] = true
                    table.insert(entries, {
                        RecordingName = name:gsub("%.json$", ""),
                        MountainName = name:gsub("^merged_", ""):gsub("_%d+$", ""),
                        MergedFile = name,
                        OwnerName = "-",
                        OwnerDisplayName = "-",
                        UpdatedAt = "-",
                        FrameCount = 0
                    })
                end
            end
        end
    end

    table.sort(entries, function(a, b)
        return tostring(a.UpdatedAt or a.MergedFile or "") > tostring(b.UpdatedAt or b.MergedFile or "")
    end)

    return entries
end

local function SaveUiState()
    if not ui.mainFrame or not ui.quickPanel then
        return
    end

    WriteJsonFile(UI_STATE_FILE, {
        MainFrame = PositionToTable(ui.mainFrame.Position),
        QuickPanel = PositionToTable(ui.quickPanel.Position),
        MainVisible = ui.mainFrame.Visible
    })
end

local function ApplySavedUiState()
    if not ui.mainFrame or not ui.quickPanel then
        return
    end

    local stateData = ReadJsonFile(UI_STATE_FILE)
    if not stateData then
        return
    end

    ui.mainFrame.Position = TableToPosition(stateData.MainFrame, ui.mainFrame.Position)
    ui.quickPanel.Position = TableToPosition(stateData.QuickPanel, ui.quickPanel.Position)
    if type(stateData.MainVisible) == "boolean" then
        ui.mainFrame.Visible = stateData.MainVisible
    end
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

local function GetFramePosition(frame)
    return Vector3.new(frame.Position[1], frame.Position[2], frame.Position[3])
end

local function GetFrameLook(frame)
    return Vector3.new(frame.LookVector[1], frame.LookVector[2], frame.LookVector[3])
end

local function GetFrameUp(frame)
    return Vector3.new(frame.UpVector[1], frame.UpVector[2], frame.UpVector[3])
end

local function GetFrameVelocity(frame, moveState)
    local velocity = Vector3.new(frame.Velocity[1], frame.Velocity[2], frame.Velocity[3])
    if moveState == nil or moveState == "Grounded" then
        return Vector3.new(velocity.X, 0, velocity.Z)
    end
    return velocity
end

local function BuildInterpolatedFrame(frameA, frameB, alpha)
    if not frameA then
        return frameB
    end
    if not frameB then
        return frameA
    end

    alpha = math.clamp(alpha or 0, 0, 1)

    local pos = GetFramePosition(frameA):Lerp(GetFramePosition(frameB), alpha)
    local look = GetFrameLook(frameA):Lerp(GetFrameLook(frameB), alpha)
    local up = GetFrameUp(frameA):Lerp(GetFrameUp(frameB), alpha)
    local velocity = GetFrameVelocity(frameA, frameA.MoveState):Lerp(GetFrameVelocity(frameB, frameB.MoveState), alpha)

    if look.Magnitude < 0.001 then
        look = GetFrameLook(frameA)
    else
        look = look.Unit
    end

    if up.Magnitude < 0.001 then
        up = GetFrameUp(frameA)
    else
        up = up.Unit
    end

    return {
        Position = {pos.X, pos.Y, pos.Z},
        LookVector = {look.X, look.Y, look.Z},
        UpVector = {up.X, up.Y, up.Z},
        Velocity = {velocity.X, velocity.Y, velocity.Z},
        WalkSpeed = (frameA.WalkSpeed or 16) + (((frameB.WalkSpeed or 16) - (frameA.WalkSpeed or 16)) * alpha),
        Timestamp = (frameA.Timestamp or 0) + (((frameB.Timestamp or 0) - (frameA.Timestamp or 0)) * alpha),
        MoveState = frameA.MoveState or frameB.MoveState
    }
end

local function ApplyPlaybackFrame(humanoid, hrp, frame)
    local currentTime = tick()
    local moveState = frame.MoveState or "Grounded"
    local frameVelocity = GetFrameVelocity(frame, moveState)

    if frameVelocity.Y > JUMP_VELOCITY_THRESHOLD and moveState ~= "Jumping" then
        moveState = "Jumping"
    elseif frameVelocity.Y < -5 and moveState ~= "Falling" then
        moveState = "Falling"
    end

    humanoid.AutoRotate = false
    humanoid.WalkSpeed = frame.WalkSpeed or 16
    hrp.CFrame = GetFrameCFrame(frame)

    if moveState == "Jumping" then
        if state.lastPlaybackState ~= "Jumping" then
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            state.lastPlaybackState = "Jumping"
            state.lastStateChangeTime = currentTime
        end
    elseif moveState == "Falling" then
        if state.lastPlaybackState ~= "Falling" then
            humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
            state.lastPlaybackState = "Falling"
            state.lastStateChangeTime = currentTime
        end
    else
        if moveState ~= state.lastPlaybackState and (currentTime - state.lastStateChangeTime) >= STATE_CHANGE_COOLDOWN then
            if moveState == "Climbing" then
                humanoid:ChangeState(Enum.HumanoidStateType.Climbing)
                humanoid.PlatformStand = false
            elseif moveState == "Swimming" then
                humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
            else
                humanoid:ChangeState(Enum.HumanoidStateType.Running)
            end
            state.lastPlaybackState = moveState
            state.lastStateChangeTime = currentTime
        end
    end

    hrp.AssemblyLinearVelocity = GetFrameVelocity(frame, moveState)
    hrp.AssemblyAngularVelocity = Vector3.zero
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
    if ui.quickStatus then
        ui.quickStatus.Text = text
        ui.quickStatus.TextColor3 = color or Theme.Text
    end
end

local function ShowLoadingScreen()
    loadingUi.screen = Instance.new("ScreenGui")
    loadingUi.screen.Name = "AutoWalkLoading"
    loadingUi.screen.ResetOnSpawn = false
    loadingUi.screen.Parent = player:WaitForChild("PlayerGui")

    local overlay = Instance.new("Frame")
    overlay.Size = UDim2.fromScale(1, 1)
    overlay.BackgroundColor3 = Color3.fromRGB(236, 246, 255)
    overlay.BorderSizePixel = 0
    overlay.Parent = loadingUi.screen
    loadingUi.overlay = overlay

    local gradient = Instance.new("UIGradient")
    gradient.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Theme.BgTop),
        ColorSequenceKeypoint.new(1, Theme.BgBottom)
    })
    gradient.Rotation = 90
    gradient.Parent = overlay

    local card = Instance.new("Frame")
    card.Size = UDim2.fromOffset(320, 150)
    card.Position = UDim2.new(0.5, -160, 0.5, -75)
    card.BackgroundColor3 = Theme.Surface
    card.BorderSizePixel = 0
    card.Parent = overlay
    CreateRounded(card, 24)
    CreateStroke(card, Theme.BorderStrong, 0.4, 1)
    loadingUi.card = card

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -30, 0, 32)
    title.Position = UDim2.fromOffset(15, 16)
    title.BackgroundTransparency = 1
    title.Text = "AutoWalk Studio"
    title.TextColor3 = Theme.Text
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 24
    title.Parent = card

    local sub = Instance.new("TextLabel")
    sub.Size = UDim2.new(1, -30, 0, 20)
    sub.Position = UDim2.fromOffset(15, 52)
    sub.BackgroundTransparency = 1
    sub.Text = "Menyiapkan data merge lokal..."
    sub.TextColor3 = Theme.TextMuted
    sub.Font = Enum.Font.Gotham
    sub.TextSize = 12
    sub.TextXAlignment = Enum.TextXAlignment.Left
    sub.Parent = card
    loadingUi.sub = sub

    local barBack = Instance.new("Frame")
    barBack.Size = UDim2.new(1, -30, 0, 12)
    barBack.Position = UDim2.fromOffset(15, 94)
    barBack.BackgroundColor3 = Theme.SurfaceSoft
    barBack.BorderSizePixel = 0
    barBack.Parent = card
    CreateRounded(barBack, 999)

    local barFill = Instance.new("Frame")
    barFill.Size = UDim2.new(0, 0, 1, 0)
    barFill.BackgroundColor3 = Theme.Primary
    barFill.BorderSizePixel = 0
    barFill.Parent = barBack
    CreateRounded(barFill, 999)
    loadingUi.barFill = barFill

    local status = Instance.new("TextLabel")
    status.Size = UDim2.new(1, -30, 0, 18)
    status.Position = UDim2.fromOffset(15, 114)
    status.BackgroundTransparency = 1
    status.Text = "Loading..."
    status.TextColor3 = Theme.TextMuted
    status.Font = Enum.Font.GothamBold
    status.TextSize = 11
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.Parent = card
    loadingUi.status = status
end

local function UpdateLoadingScreen(progress, text)
    if loadingUi.barFill then
        TweenService:Create(loadingUi.barFill, TweenInfo.new(0.2), {
            Size = UDim2.new(math.clamp(progress, 0, 1), 0, 1, 0)
        }):Play()
    end
    if loadingUi.status then
        loadingUi.status.Text = text or "Loading..."
    end
end

local function HideLoadingScreen()
    if not loadingUi.screen or not loadingUi.overlay then
        return
    end

    TweenService:Create(loadingUi.overlay, TweenInfo.new(0.35), {
        BackgroundTransparency = 1
    }):Play()
    if loadingUi.card then
        TweenService:Create(loadingUi.card, TweenInfo.new(0.35), {
            BackgroundTransparency = 1
        }):Play()
    end

    task.delay(0.4, function()
        if loadingUi.screen then
            loadingUi.screen:Destroy()
            loadingUi = {}
        end
    end)
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

local function StopAutoWalk(clearResume)
    if clearResume then
        state.pausedIndex = 1
        state.pausedTime = 0
    elseif state.isPlaying and state.frames[state.currentIndex] then
        state.pausedIndex = state.currentIndex
        state.pausedTime = state.frames[state.currentIndex].Timestamp or 0
    end
    state.isPlaying = false
    if state.connection then
        state.connection:Disconnect()
        state.connection = nil
    end
    state.playbackAccumulator = 0
    state.lastPlaybackState = nil
    state.lastStateChangeTime = 0
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

CreateRounded = function(instance, radius)
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, radius)
    corner.Parent = instance
    return corner
end

CreateStroke = function(instance, color, transparency, thickness)
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
    state.currentIndex = 1
    state.pausedIndex = 1
    state.pausedTime = 0
    state.playbackAccumulator = 0
    state.lastPlaybackState = nil
    state.lastStateChangeTime = 0

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
    local files = {}
    for _, entry in ipairs(GetLibraryEntries()) do
        table.insert(files, entry.MergedFile)
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

    local entries = GetLibraryEntries()
    local y = 0

    if #entries == 0 then
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
        label.Text = "Belum ada history merge yang tersimpan."
        label.TextColor3 = Theme.TextMuted
        label.Font = Enum.Font.Gotham
        label.TextSize = 12
        label.TextWrapped = true
        label.Parent = empty

        ui.libraryList.CanvasSize = UDim2.new(0, 0, 0, 56)
        return
    end

    for _, entry in ipairs(entries) do
        local fileName = entry.MergedFile or "-"
        local mountainName = Trim(entry.MountainName or "") ~= "" and entry.MountainName or fileName
        local ownerText = Trim(entry.OwnerName or "") ~= "" and ("@" .. entry.OwnerName) or "owner tidak diketahui"
        local frameText = tonumber(entry.FrameCount) and tostring(entry.FrameCount) or "0"
        local updatedAt = entry.UpdatedAt or "-"

        local item = Instance.new("Frame")
        item.Size = UDim2.new(1, 0, 0, 72)
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
        nameLabel.Text = mountainName
        nameLabel.TextColor3 = Theme.Text
        nameLabel.Font = Enum.Font.GothamBold
        nameLabel.TextSize = 12
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Parent = item

        local hintLabel = Instance.new("TextLabel")
        hintLabel.Size = UDim2.new(1, -100, 0, 16)
        hintLabel.Position = UDim2.fromOffset(10, 30)
        hintLabel.BackgroundTransparency = 1
        hintLabel.Text = string.format("%s | %s frame", ownerText, frameText)
        hintLabel.TextColor3 = Theme.TextMuted
        hintLabel.Font = Enum.Font.Gotham
        hintLabel.TextSize = 11
        hintLabel.TextXAlignment = Enum.TextXAlignment.Left
        hintLabel.Parent = item

        local infoLabel = Instance.new("TextLabel")
        infoLabel.Size = UDim2.new(1, -100, 0, 16)
        infoLabel.Position = UDim2.fromOffset(10, 46)
        infoLabel.BackgroundTransparency = 1
        infoLabel.Text = string.format("%s | %s", fileName, updatedAt)
        infoLabel.TextColor3 = Theme.TextMuted
        infoLabel.Font = Enum.Font.Gotham
        infoLabel.TextSize = 10
        infoLabel.TextXAlignment = Enum.TextXAlignment.Left
        infoLabel.Parent = item

        local loadButton = CreateButton(item, "LOAD", UDim2.new(1, -74, 0, 15), UDim2.fromOffset(64, 30), Theme.Primary, Theme.PrimaryDark)
        loadButton.MouseButton1Click:Connect(function()
            StopAutoWalk()
            LoadMergeDataFromFile(fileName)
            SetCurrentPage("home")
        end)

        y = y + 80
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
    local resumeIndex = math.clamp(state.pausedIndex or 1, 1, #state.frames)
    local resumeTime = math.max(state.pausedTime or 0, 0)

    if resumeIndex > #state.frames then
        resumeIndex = 1
        resumeTime = 0
    end

    state.currentIndex = resumeIndex
    state.startTime = tick() - (resumeTime / state.playbackSpeed)
    state.playbackAccumulator = 0
    state.lastPlaybackState = nil
    state.lastStateChangeTime = 0

    local startFrame = state.frames[state.currentIndex] or state.frames[1]
    hrp.CFrame = GetFrameCFrame(startFrame)
    hrp.AssemblyLinearVelocity = Vector3.zero
    hrp.AssemblyAngularVelocity = Vector3.zero
    SetStatus(resumeTime > 0 and "RESUMED" or "PLAYING", Theme.Green)

    state.connection = RunService.Heartbeat:Connect(function(deltaTime)
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

        state.playbackAccumulator = state.playbackAccumulator + deltaTime

        while state.playbackAccumulator >= PLAYBACK_FIXED_TIMESTEP do
            state.playbackAccumulator = state.playbackAccumulator - PLAYBACK_FIXED_TIMESTEP

            local effectiveTime = (tick() - state.startTime) * state.playbackSpeed
            local nextIndex = state.currentIndex
            while nextIndex < #state.frames and (state.frames[nextIndex + 1].Timestamp or 0) <= effectiveTime do
                nextIndex = nextIndex + 1
            end

            if nextIndex > #state.frames then
                StopAutoWalk()
                return
            end

            local baseFrame = state.frames[nextIndex]
            if not baseFrame then
                StopAutoWalk()
                return
            end

            local frameToApply = baseFrame
            local nextFrame = state.frames[nextIndex + 1]
            if nextFrame then
                local currentTimestamp = baseFrame.Timestamp or 0
                local nextTimestamp = nextFrame.Timestamp or currentTimestamp
                local duration = math.max(nextTimestamp - currentTimestamp, 0.0001)
                local alpha = math.clamp((effectiveTime - currentTimestamp) / duration, 0, 1)
                frameToApply = BuildInterpolatedFrame(baseFrame, nextFrame, alpha)
            end

            ApplyPlaybackFrame(humanoid, hrp, frameToApply)
            state.currentIndex = nextIndex
            state.pausedIndex = state.currentIndex
            state.pausedTime = frameToApply.Timestamp or (baseFrame.Timestamp or 0)

            if state.currentIndex >= #state.frames then
                StopAutoWalk(true)
                return
            end
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
    ui.quickPanel.Size = UDim2.fromOffset(206, 52)
    ui.quickPanel.Position = UDim2.new(0, 122, 0, 12)
    ui.quickPanel.BackgroundColor3 = Theme.Surface
    ui.quickPanel.BackgroundTransparency = 0.12
    ui.quickPanel.BorderSizePixel = 0
    ui.quickPanel.Active = true
    ui.quickPanel.Draggable = true
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

    ui.quickStatus = Instance.new("TextLabel")
    ui.quickStatus.Size = UDim2.fromOffset(74, 18)
    ui.quickStatus.Position = UDim2.fromOffset(10, 4)
    ui.quickStatus.BackgroundTransparency = 1
    ui.quickStatus.Text = "READY"
    ui.quickStatus.TextColor3 = Theme.Green
    ui.quickStatus.Font = Enum.Font.GothamBold
    ui.quickStatus.TextSize = 11
    ui.quickStatus.TextXAlignment = Enum.TextXAlignment.Left
    ui.quickStatus.Parent = ui.quickPanel

    local quickHint = Instance.new("TextLabel")
    quickHint.Size = UDim2.fromOffset(108, 16)
    quickHint.Position = UDim2.fromOffset(88, 5)
    quickHint.BackgroundTransparency = 1
    quickHint.Text = "Drag panel ini"
    quickHint.TextColor3 = Theme.TextMuted
    quickHint.Font = Enum.Font.Gotham
    quickHint.TextSize = 10
    quickHint.TextXAlignment = Enum.TextXAlignment.Right
    quickHint.Parent = ui.quickPanel

    local quickPlay = CreateButton(ui.quickPanel, "PLAY", UDim2.fromOffset(8, 20), UDim2.fromOffset(90, 24), Theme.Green, Theme.GreenDark)
    quickPlay.TextSize = 11
    CreateRounded(quickPlay, 12)

    local quickStop = CreateButton(ui.quickPanel, "STOP", UDim2.fromOffset(108, 20), UDim2.fromOffset(90, 24), Theme.Red, Theme.RedDark)
    quickStop.TextSize = 11
    CreateRounded(quickStop, 12)

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
    ui.mainFrame:GetPropertyChangedSignal("Position"):Connect(SaveUiState)
    ui.quickPanel:GetPropertyChangedSignal("Position"):Connect(SaveUiState)

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
        SaveUiState()
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

    ApplySavedUiState()
    ui.toggleButton.Text = ui.mainFrame.Visible and "Hide UI" or "Show UI"
end

ShowLoadingScreen()
UpdateLoadingScreen(0.2, "Menyiapkan antarmuka...")
CreateUI()
UpdateLoadingScreen(0.5, "Memuat ringkasan...")
RefreshOverview()
UpdateLoadingScreen(0.72, "Membaca daftar merge permanen...")
RefreshLibrary()
SetCurrentPage("home")
UpdateLoadingScreen(0.9, "Menghubungkan merge terakhir...")
LoadLatestBridge()
UpdateLoadingScreen(1, "Selesai")
HideLoadingScreen()
