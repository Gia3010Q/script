-- JoinTheoAcc V4.2 - gop GUI + JOIN trong 1 UI, 2 nut ON/OFF rieng.
-- Acc gui: tu bao PlaceId + JobId cua chinh account nay.
-- Acc join theo: bam nut JOIN THEO de theo acc gui tren kenh chung.
-- CHI BAT MOT trong 2 nut ON. Bam nut con lai se tu tat nut kia.
-- Dung Follow API V1 hien co; khong can sua API hosting.

getgenv().JoinTheoAccConfig = getgenv().JoinTheoAccConfig or {}
local config = getgenv().JoinTheoAccConfig
local defaults = {
    ["API Base URL"] = "https://giaapi.sotarstudio.online",
    ["API Key"] = "",
    ["Heartbeat Interval"] = 1.5,
    ["Poll Interval"] = 1.0,
    ["Max Target Age"] = 10.0,
    ["Teleport Cooldown"] = 8.0,
}
for key, value in pairs(defaults) do
    if config[key] == nil then config[key] = value end
end

-- Follow API chap nhan key nay trong truong leader; khong phai username.
local FOLLOW_CHANNEL = "JoinTheoAccShared"

local previous = getgenv().__JoinTheoAccController
if previous and previous.version == 42 and previous.running then
    if previous.screenGui and previous.screenGui.Parent then
        previous.screenGui.Enabled = true
    end
    warn("JoinTheoAcc V4.2 dang chay - mo lai UI, khong tao loop trung.")
    return
end
if previous then
    if type(previous.stop) == "function" then
        pcall(previous.stop)
    else
        previous.running = false
        previous.enabled = false
        previous.leaving = true
        previous.teleporting = true
        previous.lastAttemptAt = math.huge
        if previous.screenGui then pcall(function() previous.screenGui:Destroy() end) end
    end
end

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local CoreGui = game:GetService("CoreGui")
local player = Players.LocalPlayer or Players.PlayerAdded:Wait()

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function sameName(left, right)
    return string.lower(trim(left)) == string.lower(trim(right))
end

local apiBase = trim(config["API Base URL"]):gsub("/+$", "")
local apiKey = tostring(config["API Key"] or "")
local heartbeatInterval = math.max(0.8, tonumber(config["Heartbeat Interval"]) or 1.5)
local pollInterval = math.max(0.6, tonumber(config["Poll Interval"]) or 1.0)
local maxTargetAge = math.max(3, tonumber(config["Max Target Age"]) or 10)
local teleportCooldown = math.max(5, tonumber(config["Teleport Cooldown"]) or 8)
local requestFunction = http_request
    or (http and http.request)
    or request
    or (syn and syn.request)
    or (fluxus and fluxus.request)

local controller = {
    version = 42,
    running = true,
    role = "none",
    enabled = false,
    epoch = 0,
    sessionId = nil,
    channel = FOLLOW_CHANNEL,
    lastStatus = "",
    lastAttemptAt = -math.huge,
    lastTargetJob = "",
    teleporting = false,
    blockedRevision = nil,
    currentRevision = nil,
    apiReady = false,
    leaving = false,
    connections = {},
    pendingLeaves = {},
}
getgenv().__JoinTheoAccController = controller

local function ownsController()
    return controller.running and getgenv().__JoinTheoAccController == controller
end

local function isCurrent(epoch, role)
    return ownsController() and controller.enabled
        and controller.epoch == epoch and controller.role == role
end

local function setStatus(key, message)
    if not ownsController() or controller.lastStatus == key then return end
    controller.lastStatus = key
    if controller.statusLabel then
        controller.statusLabel.Text = tostring(message)
        controller.statusLabel.TextColor3 = Color3.fromRGB(198, 225, 235)
    end
    warn("JoinTheoAcc V4.2: " .. tostring(message))
end

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(controller.connections, connection)
    return connection
end

local function queueLeaving(sessionId)
    if sessionId then controller.pendingLeaves[sessionId] = true end
end

local function pauseActivity()
    if controller.enabled and controller.role == "leader" then
        queueLeaving(controller.sessionId)
    end
    controller.enabled = false
    controller.epoch = controller.epoch + 1
    controller.teleporting = false
    controller.lastAttemptAt = -math.huge
    controller.lastTargetJob = ""
    controller.blockedRevision = nil
    controller.currentRevision = nil
    controller.lastStatus = ""
end

function controller.stop()
    if not controller.running then return end
    pauseActivity()
    controller.running = false
    for _, connection in ipairs(controller.connections) do connection:Disconnect() end
    table.clear(controller.connections)
    if controller.screenGui then controller.screenGui:Destroy() end
end

-- Bam nut vai tro: neu dang ON dung vai tro do thi TAT; neu khac thi chuyen sang vai tro do.
local function toggleRole(role)
    if not ownsController() then return end
    -- Dang ON dung vai tro nay -> tat
    if controller.enabled and controller.role == role then
        pauseActivity()
        controller.role = "none"
        controller.leaving = false
        controller.refreshUI()
        setStatus("off_" .. role, role == "leader"
            and "Da OFF GUI. Khong bao server nua."
            or "Da OFF JOIN. Khong teleport nua.")
        return
    end
    -- Neu dang ON vai tro khac -> tat truoc
    if controller.enabled then
        pauseActivity()
    end
    if apiBase == "" or type(requestFunction) ~= "function" then
        setStatus("missing_http", "Thieu API Base URL hoac executor khong ho tro HTTP request.")
        return
    end
    controller.role = role
    controller.leaving = false
    if role == "leader" then
        controller.sessionId = HttpService:GenerateGUID(false)
    end
    controller.epoch = controller.epoch + 1
    controller.enabled = true
    controller.lastStatus = ""
    controller.refreshUI()
    setStatus("on_" .. role, role == "leader"
        and ("Dang GUI server cua " .. player.Name .. "...")
        or "Dang tim acc gui tren kenh chung...")
end

local function makeHeaders()
    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json",
        ["Cache-Control"] = "no-cache",
    }
    if apiKey ~= "" then headers["X-API-Key"] = apiKey end
    return headers
end

local function apiRequest(method, path, body)
    local options = {
        Url = apiBase .. path,
        Method = method,
        Headers = makeHeaders(),
    }
    if body ~= nil then options.Body = HttpService:JSONEncode(body) end

    local ok, response = pcall(requestFunction, options)
    if not ok then return nil, 0, "request_failed: " .. tostring(response) end
    if type(response) ~= "table" then return nil, 0, "invalid_response" end

    local statusCode = tonumber(
        response.StatusCode or response.Status or response.status_code or response.status
    ) or 0
    local rawBody = response.Body or response.body or ""
    local decoded = nil
    if type(rawBody) == "string" and rawBody ~= "" then
        local decodedOk, value = pcall(HttpService.JSONDecode, HttpService, rawBody)
        if decodedOk then decoded = value end
    end

    if statusCode < 200 or statusCode >= 300 then
        local serverError = type(decoded) == "table" and (decoded.error or decoded.reason)
        return decoded, statusCode, tostring(serverError or ("http_" .. statusCode))
    end
    if type(decoded) ~= "table" then return nil, statusCode, "invalid_json" end
    return decoded, statusCode, nil
end

local function createControlUI()
    local playerGui = player:WaitForChild("PlayerGui")
    local parents = {}
    if type(gethui) == "function" then
        local ok, parent = pcall(gethui)
        if ok and parent then table.insert(parents, parent) end
    end
    table.insert(parents, CoreGui)
    table.insert(parents, playerGui)

    local screen = Instance.new("ScreenGui")
    screen.Name = "JoinTheoAccUI"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = false
    screen.DisplayOrder = 999
    for _, parent in ipairs(parents) do
        local ok = pcall(function()
            local old = parent:FindFirstChild("JoinTheoAccUI")
            if old then old:Destroy() end
            screen.Parent = parent
        end)
        if ok and screen.Parent then break end
    end
    assert(screen.Parent, "Khong gan duoc UI vao PlayerGui/CoreGui")
    controller.screenGui = screen

    local function corner(object, radius)
        local value = Instance.new("UICorner")
        value.CornerRadius = UDim.new(0, radius or 7)
        value.Parent = object
    end

    local main = Instance.new("Frame")
    main.Name = "Main"
    main.AnchorPoint = Vector2.new(0.5, 0)
    main.Position = UDim2.new(0.5, 0, 0, 72)
    main.Size = UDim2.fromOffset(360, 240)
    main.BackgroundColor3 = Color3.fromRGB(7, 20, 29)
    main.BorderSizePixel = 0
    main.Parent = screen
    corner(main, 11)

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(0, 210, 235)
    stroke.Thickness = 1.5
    stroke.Transparency = 0.12
    stroke.Parent = main

    local function text(parent, name, content, x, y, width, height, size)
        local label = Instance.new("TextLabel")
        label.Name = name
        label.BackgroundTransparency = 1
        label.Position = UDim2.fromOffset(x, y)
        label.Size = UDim2.fromOffset(width, height)
        label.Font = Enum.Font.Gotham
        label.Text = content
        label.TextSize = size or 12
        label.TextColor3 = Color3.fromRGB(225, 240, 245)
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.Parent = parent
        return label
    end

    local function button(parent, name, caption, x, y, width, height)
        local value = Instance.new("TextButton")
        value.Name = name
        value.Position = UDim2.fromOffset(x, y)
        value.Size = UDim2.fromOffset(width, height)
        value.BackgroundColor3 = Color3.fromRGB(23, 45, 59)
        value.BorderSizePixel = 0
        value.Font = Enum.Font.GothamBold
        value.Text = caption
        value.TextSize = 13
        value.TextColor3 = Color3.fromRGB(225, 240, 245)
        value.AutoButtonColor = true
        value.Parent = parent
        corner(value)
        return value
    end

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 38)
    header.BackgroundColor3 = Color3.fromRGB(10, 31, 42)
    header.BorderSizePixel = 0
    header.Active = true
    header.Parent = main
    corner(header, 11)

    local title = text(header, "Title", "JOIN THEO ACC  -  V4.2", 13, 0, 262, 38, 14)
    title.Font = Enum.Font.GothamBold
    title.TextColor3 = Color3.fromRGB(51, 225, 245)
    local closeButton = button(header, "Close", "X", 324, 6, 27, 27)
    closeButton.BackgroundColor3 = Color3.fromRGB(73, 24, 42)
    local minimizeButton = button(header, "Minimize", "-", 293, 6, 27, 27)
    minimizeButton.TextSize = 16

    local accountLabel = text(main, "Account", "Acc hien tai: " .. player.Name, 14, 44, 332, 20, 13)
    accountLabel.TextTruncate = Enum.TextTruncate.AtEnd

    local senderButton = button(main, "SenderRole", "GUI SERVER: OFF", 12, 72, 164, 46)
    local followerButton = button(main, "FollowerRole", "JOIN THEO: OFF", 184, 72, 164, 46)

    local channelHint = text(main, "ChannelHint",
        "Bam nut nao de bat vai tro do. Chi 1 nut ON tai 1 thoi diem.", 14, 124, 332, 30, 12)
    channelHint.TextWrapped = true
    channelHint.TextColor3 = Color3.fromRGB(255, 200, 110)

    local statusLabel = text(main, "Status", "", 12, 158, 336, 70, 12)
    statusLabel.BackgroundTransparency = 0
    statusLabel.BackgroundColor3 = Color3.fromRGB(4, 15, 22)
    statusLabel.BorderSizePixel = 0
    statusLabel.TextWrapped = true
    corner(statusLabel)
    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 10)
    padding.PaddingRight = UDim.new(0, 10)
    padding.PaddingTop = UDim.new(0, 6)
    padding.Parent = statusLabel

    controller.statusLabel = statusLabel

    function controller.refreshUI()
        local senderOn = controller.enabled and controller.role == "leader"
        local followerOn = controller.enabled and controller.role == "follower"

        senderButton.BackgroundColor3 = senderOn
            and Color3.fromRGB(14, 116, 83) or Color3.fromRGB(65, 38, 47)
        senderButton.Text = senderOn and "GUI SERVER: ON" or "GUI SERVER: OFF"

        followerButton.BackgroundColor3 = followerOn
            and Color3.fromRGB(14, 116, 83) or Color3.fromRGB(65, 38, 47)
        followerButton.Text = followerOn and "JOIN THEO: ON" or "JOIN THEO: OFF"
    end
    controller.refreshUI()

    connect(senderButton.Activated, function() toggleRole("leader") end)
    connect(followerButton.Activated, function() toggleRole("follower") end)
    connect(closeButton.Activated, controller.stop)

    -- Nut "-" thu nho UI: chi con thanh tieu de. Bam "+" de mo rong lai.
    local minimized = false
    connect(minimizeButton.Activated, function()
        minimized = not minimized
        for _, child in ipairs(main:GetChildren()) do
            if child:IsA("GuiObject") and child ~= header then
                child.Visible = not minimized
            end
        end
        main.Size = minimized and UDim2.fromOffset(360, 38) or UDim2.fromOffset(360, 240)
        minimizeButton.Text = minimized and "+" or "-"
    end)

    local dragging, dragInput, dragStart, startPosition
    connect(header.InputBegan, function(input)
        if input.UserInputType ~= Enum.UserInputType.MouseButton1
            and input.UserInputType ~= Enum.UserInputType.Touch then return end
        dragging = true
        dragInput = input
        dragStart = input.Position
        startPosition = main.Position
    end)
    connect(header.InputChanged, function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement then dragInput = input end
    end)
    connect(UserInputService.InputEnded, function(input)
        if input == dragInput or input.UserInputType == Enum.UserInputType.MouseButton1 then
            dragging = false
        end
    end)
    connect(UserInputService.InputChanged, function(input)
        if not ownsController() or not dragging or input ~= dragInput then return end
        local delta = input.Position - dragStart
        main.Position = UDim2.new(startPosition.X.Scale, startPosition.X.Offset + delta.X,
            startPosition.Y.Scale, startPosition.Y.Offset + delta.Y)
    end)
end

local uiOk, uiError = pcall(createControlUI)
if not uiOk then
    controller.stop()
    warn("JoinTheoAcc V4.2: khong tao duoc UI: " .. tostring(uiError))
    return
end
setStatus("choose_role", "Bam nut GUI SERVER hoac JOIN THEO de bat vai tro.")

-- Chi mot worker gui request: OFF/doi vai tro xep "leaving" sau heartbeat
-- dang cho. Nhu vay heartbeat cu khong the den muon va mo lai JobId da tat.
local function flushLeaving()
    for sessionId in pairs(controller.pendingLeaves) do
        controller.pendingLeaves[sessionId] = nil
        apiRequest("POST", "/follow/v1/report", {
            leader = FOLLOW_CHANNEL,
            state = "leaving",
            sessionId = sessionId,
            clientTime = workspace:GetServerTimeNow(),
        })
    end
end

local function reportSender(epoch, sessionId)
    if game.JobId == "" or not game.PlaceId then
        setStatus("job_not_ready", "Roblox chua co PlaceId/JobId. Dang cho...")
        return
    end
    local response, statusCode, requestError = apiRequest("POST", "/follow/v1/report", {
        leader = FOLLOW_CHANNEL,
        placeId = tostring(game.PlaceId),
        jobId = tostring(game.JobId),
        universeId = tostring(game.GameId),
        privateServerId = tostring(game.PrivateServerId or ""),
        privateServerOwnerId = tostring(game.PrivateServerOwnerId or ""),
        sessionId = sessionId,
        clientTime = workspace:GetServerTimeNow(),
    })
    if not isCurrent(epoch, "leader") then
        queueLeaving(sessionId)
        return
    end
    if response and response.accepted == true and not requestError then
        controller.revision = response.revision
        setStatus("sender_online_" .. tostring(game.JobId),
            "DANG GUI: " .. player.Name .. " | JobId ..." .. tostring(game.JobId):sub(-8))
    else
        setStatus("sender_error_" .. tostring(requestError),
            "Khong gui duoc heartbeat: " .. tostring(requestError or ("HTTP " .. statusCode)))
    end
end

local function followTarget(epoch)
    local target, statusCode, requestError = apiRequest(
        "GET", "/follow/v1/target/" .. HttpService:UrlEncode(FOLLOW_CHANNEL)
    )
    if not isCurrent(epoch, "follower") then return end
    if requestError or not target then
        setStatus("api_error_" .. tostring(statusCode) .. "_" .. tostring(requestError),
            "Khong doc duoc API: HTTP " .. tostring(statusCode) .. " | " .. tostring(requestError))
        return
    end
    if target.leader and not sameName(target.leader, FOLLOW_CHANNEL) then
        setStatus("wrong_channel", "API tra ve sai kenh chung; khong teleport.")
        return
    end
    if target.online ~= true then
        controller.teleporting = false
        setStatus("sender_offline_" .. tostring(target.reason),
            "Acc gui chua san sang: " .. tostring(target.reason or "offline"))
        return
    end

    local targetJob = tostring(target.jobId or "")
    local targetPlace = tonumber(target.placeId)
    local targetUniverse = tostring(target.universeId or "")
    local revision = tonumber(target.revision) or 0
    local age = tonumber(target.ageSec) or math.huge
    if targetJob == "" or not targetPlace or targetPlace <= 0 or targetPlace % 1 ~= 0 then
        setStatus("invalid_target", "API tra ve PlaceId/JobId khong hop le.")
    elseif age > maxTargetAge then
        setStatus("target_stale", "Heartbeat acc gui qua cu: " .. tostring(age) .. "s.")
    elseif target.isReserved == true then
        controller.blockedRevision = revision
        setStatus("reserved_" .. revision, "Server reserved/private: JobId khong du quyen de join truc tiep.")
    elseif targetUniverse ~= "" and targetUniverse ~= tostring(game.GameId) then
        controller.blockedRevision = revision
        setStatus("wrong_universe_" .. revision, "Server dich thuoc Universe khac; khong teleport.")
    elseif targetJob == game.JobId and targetPlace == game.PlaceId then
        controller.teleporting = false
        controller.blockedRevision = nil
        controller.lastTargetJob = targetJob
        setStatus("same_server_" .. targetJob, "Da o cung server voi acc gui | JobId ..." .. targetJob:sub(-8))
    elseif controller.blockedRevision == revision then
        setStatus("blocked_" .. revision, "Dang cho acc gui doi sang server join duoc.")
    elseif not controller.teleporting and os.clock() - controller.lastAttemptAt >= teleportCooldown then
        controller.teleporting = true
        controller.lastAttemptAt = os.clock()
        controller.lastTargetJob = targetJob
        controller.currentRevision = revision
        setStatus("teleport_" .. targetJob,
            "Dang join acc gui | Place " .. tostring(targetPlace) .. " | Job ..." .. targetJob:sub(-8))
        local serverBrowser = ReplicatedStorage:FindFirstChild("__ServerBrowser")
        local called, callError = pcall(function()
            if serverBrowser then
                serverBrowser:InvokeServer("teleport", targetJob)
            else
                TeleportService:TeleportToPlaceInstance(targetPlace, targetJob, player)
            end
        end)
        if not isCurrent(epoch, "follower") then return end
        if not called then
            controller.teleporting = false
            setStatus("teleport_call_error_" .. tostring(callError), "Loi goi teleport: " .. tostring(callError))
        else
            task.delay(teleportCooldown, function()
                if not isCurrent(epoch, "follower") then return end
                if controller.lastTargetJob == targetJob and game.JobId ~= targetJob then
                    controller.teleporting = false
                    controller.lastStatus = ""
                end
            end)
        end
    end
end

connect(TeleportService.TeleportInitFailed, function(failedPlayer, teleportResult, errorMessage)
    if failedPlayer ~= player or not ownsController()
        or controller.role ~= "follower" or not controller.enabled
        or not controller.teleporting then return end
    controller.teleporting = false
    controller.lastAttemptAt = os.clock()
    local failure = tostring(teleportResult) .. " | " .. tostring(errorMessage)
    local lower = string.lower(failure)
    if lower:find("restricted", 1, true) or lower:find("773", 1, true) then
        controller.blockedRevision = controller.currentRevision
        setStatus("restricted_" .. tostring(controller.currentRevision),
            "Place bi restricted (773); doi acc gui doi server hoac bam OFF/ON de thu lai.")
    else
        setStatus("teleport_failed_" .. failure, "Roblox tu choi teleport: " .. failure)
    end
end)

connect(player.OnTeleport, function(state)
    if not ownsController() or state ~= Enum.TeleportState.Started then return end
    if controller.role == "leader" and controller.enabled then
        controller.leaving = true
        pauseActivity()
        controller.role = "none"
        controller.refreshUI()
        setStatus("sender_leaving", "Acc gui dang doi server; ngung phat JobId cu.")
    elseif controller.role == "follower" and controller.enabled then
        setStatus("teleport_started", "Roblox da bat dau chuyen server.")
    end
end)

local function runOnce(epoch)
    if not controller.apiReady then
        local health, statusCode, requestError = apiRequest("GET", "/health")
        if not ownsController() or controller.epoch ~= epoch or not controller.enabled then return 0 end
        if requestError or not health or health.followApi ~= "v1" then
            setStatus("health_error_" .. tostring(statusCode) .. tostring(requestError),
                "API chua san sang / thieu Follow API V1. HTTP " .. tostring(statusCode)
                    .. " | " .. tostring(requestError or "followApi_missing") .. ". Dang thu lai...")
            return 2
        end
        controller.apiReady = true
    end
    if controller.role == "leader" then
        reportSender(epoch, controller.sessionId)
        return heartbeatInterval
    elseif controller.role == "follower" then
        followTarget(epoch)
        return pollInterval
    end
    return 0.1
end

while ownsController() do
    flushLeaving()
    if not ownsController() then break end
    local epoch = controller.epoch
    local interval = 0.1
    if controller.enabled then
        local ok, result = pcall(runOnce, epoch)
        if ok then
            interval = result or pollInterval
        elseif controller.epoch == epoch then
            controller.teleporting = false
            setStatus("worker_error_" .. tostring(result), "Loi xu ly, se thu lai: " .. tostring(result))
            interval = 2
        end
    end
    local untilTime = os.clock() + interval
    repeat
        task.wait(0.1)
    until not ownsController() or controller.epoch ~= epoch or os.clock() >= untilTime
end
pcall(flushLeaving)
