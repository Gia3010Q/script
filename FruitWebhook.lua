--[[
    FruitWebhook.lua - Script thông báo Discord Webhook độc lập cho Blox Fruits.
    Tách từ EvenMagnetFarm.lua / auto_factory.lua.

    Tính năng:
      1. Chạy ĐỘC LẬP:
         - Tự động phát hiện khi CẦM TRÁI TRÊN TAY (Holding Fruit).
         - Tự động phát hiện khi NHẶT TRÁI từ map (Picked Fruit).
         - Tự động phát hiện khi QUAY TRÁI Gacha / Cousin (Random Fruit).
         - Tự động phát hiện khi CẤT TRÁI vào rương (Stored Fruit).
      2. Chạy KẾT HỢP với EvenMagnetFarm.lua, EvenMagnetFarm_V2.lua hoặc các farm script khác qua API:
         getgenv().SendFruitWebhook(eventType, fruitName, tool, storageName)
      3. Lọc Rarity thông minh: All, Common, Uncommon, Rare, Legendary, Mythical.
      4. Hỗ trợ mọi Executor (Synapse, Fluxus, Delta, Wave, Codex, Argon, Hydrogen, v.v.).
      5. Hàng đợi thông minh (Queue) chống Discord Rate Limit (0.5s/request) và chống spam trùng lặp.

    Cấu hình nhanh trước khi chạy (tùy chọn):
      getgenv().WebhookURL = "https://discord.com/api/webhooks/..."
      getgenv().WebhookOnlyFruit = "Gas" -- Mặc định chỉ nhận Hellfire (Gas) Fruit. Đặt "All" nếu muốn nhận tất cả.
      getgenv().WebhookPing = "@everyone" -- Mặc định ping @everyone khi có thông báo
      getgenv().WebhookMinRarity = "All" -- "All" | "Common" | "Uncommon" | "Rare" | "Legendary" | "Mythical"
      getgenv().AutoStore = true         -- Tự động lưu trái vào rương càng nhanh càng tốt
      getgenv().MaxStoreAttempts = 2     -- Thử tối đa 2 lần, nếu không thể lưu thì bỏ qua hoàn toàn
      getgenv().StoreRetryDelay = 0.3    -- Thử lại cực nhanh (0.3s) giữa 2 lần thử

    Hoặc cấu hình đầy đủ bằng bảng:
      getgenv().FruitWebhookConfig = {
          WebhookURL = "https://discord.com/api/webhooks/...",
          OnlyFruit = "Gas", -- Chỉ nhận Hellfire / Gas Fruit (hoặc "All")
          Ping = "@everyone", -- Mặc định ping @everyone
          AutoStore = true,  -- Tự động lưu trái vào rương
          MaxStoreAttempts = 2,  -- Tối đa 2 lần thử, thất bại bỏ qua hoàn toàn
          StoreRetryDelay = 0.3, -- Delay thử lại cực nhanh (giây)
          Enabled = true,
          OnHolding = true, -- Thông báo khi cầm trái trên tay
          OnPickup = true,  -- Thông báo khi nhặt trái
          OnRandom = true,  -- Thông báo khi quay gacha
          OnStore = true,   -- Thông báo khi cất rương
          MinRarity = "All", -- "All" | "Legendary" | "Mythical" ...
          Username = "Noti Fruit",
          Title = "🔥 Noti Hellfire (Gas) Fruit",
          FooterText = "Dev By Gia Yêu Em",
          Color = 16711765, -- Màu đỏ Ruby Mythical
          AvatarURL = "",
          BannerURL = "",
          AutoDetect = true, -- Tự động bắt sự kiện khi chạy độc lập
      }
--]]

local env = (type(getgenv) == "function" and getgenv()) or _G

-- Dọn dẹp phiên bản cũ nếu chạy lại
local previous = env.FruitWebhookController
if type(previous) == "table" and type(previous.Stop) == "function" then
    pcall(previous.Stop)
end

repeat task.wait() until game:IsLoaded() and game:GetService("Players").LocalPlayer

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer

-- Cấu hình mặc định: Mặc định lọc riêng trái Hellfire (Gas) Fruit & Auto Store siêu tốc
local defaults = {
    Enabled = true,
    WebhookURL = "",
    OnlyFruit = "Gas", -- "Gas" (Hellfire / Gas Fruit) hoặc "All" để nhận tất cả các trái
    AutoStore = true,  -- Tự động lưu trái vào rương càng nhanh càng tốt
    MaxStoreAttempts = 2,  -- Tối đa 2 lần thử, nếu thất bại bỏ qua hoàn toàn
    StoreRetryDelay = 0.3, -- Thời gian chờ thử lại (0.3 giây)
    OnHolding = true,
    OnPickup = true,
    OnRandom = true,
    OnStore = true,
    MinRarity = "All", -- Nhận tất cả trái phù hợp với OnlyFruit
    Username = "Noti Fruit",
    Title = "🔥 Noti Hellfire (Gas) Fruit",
    FooterText = "Dev By Gia Yêu Em",
    Color = nil, -- nil = tự dùng màu Rarity (Đỏ Ruby cho Gas/Hellfire Mythical)
    Ping = "@everyone", -- Mặc định ping @everyone khi có thông báo
    AvatarURL = "",
    BannerURL = "",
    AutoDetect = true,
}

-- Hợp nhất cấu hình từ FruitWebhookConfig hoặc biến môi trường toàn cục
local config = table.clone(defaults)
local userConfig = env.FruitWebhookConfig
if type(userConfig) == "table" then
    for k, v in pairs(userConfig) do
        config[k] = v
    end
end

-- Tương thích ngược với các biến getgenv độc lập của EvenMagnetFarm / auto_factory
if type(env.WebhookURL) == "string" and env.WebhookURL ~= "" then
    config.WebhookURL = env.WebhookURL
end
if type(env.WebhookOnlyFruit) == "string" and env.WebhookOnlyFruit ~= "" then
    config.OnlyFruit = env.WebhookOnlyFruit
end
if type(env.OnlyFruit) == "string" and env.OnlyFruit ~= "" then
    config.OnlyFruit = env.OnlyFruit
end
if type(env.WebhookMinRarity) == "string" and env.WebhookMinRarity ~= "" then
    config.MinRarity = env.WebhookMinRarity
end
if env.AutoStore ~= nil then config.AutoStore = env.AutoStore end
if env.StoreFruit ~= nil then config.AutoStore = env.StoreFruit end
if tonumber(env.MaxStoreAttempts) then config.MaxStoreAttempts = tonumber(env.MaxStoreAttempts) end
if tonumber(env.StoreAttempts) then config.MaxStoreAttempts = tonumber(env.StoreAttempts) end
if tonumber(env.StoreRetryDelay) then config.StoreRetryDelay = tonumber(env.StoreRetryDelay) end
if env.WebhookEnabled ~= nil then config.Enabled = env.WebhookEnabled end
if env.WebhookOnHolding ~= nil then config.OnHolding = env.WebhookOnHolding end
if env.WebhookOnPickup ~= nil then config.OnPickup = env.WebhookOnPickup end
if env.WebhookOnRandom ~= nil then config.OnRandom = env.WebhookOnRandom end
if env.WebhookOnStore ~= nil then config.OnStore = env.WebhookOnStore end
if type(env.WebhookPing) == "string" then config.Ping = env.WebhookPing end
if type(env.WebhookAvatarURL) == "string" then config.AvatarURL = env.WebhookAvatarURL end
if type(env.WebhookBannerURL) == "string" then config.BannerURL = env.WebhookBannerURL end
if type(env.WebhookTitle) == "string" then config.Title = env.WebhookTitle end
if type(env.WebhookUsername) == "string" then config.Username = env.WebhookUsername end
if type(env.WebhookFooterText) == "string" then config.FooterText = env.WebhookFooterText end
if type(env.WebhookColor) == "number" then config.Color = env.WebhookColor end

local function log(tag, message)
    print(string.format("[%s] [FruitWebhook] [%s] %s", os.date("%H:%M:%S"), tostring(tag or "INFO"), tostring(message or "")))
end

-- Hàm tìm Executor HTTP Request an toàn
local function getHttpRequest()
    return (type(request) == "function" and request)
        or (type(http_request) == "function" and http_request)
        or (type(syn) == "table" and type(syn.request) == "function" and syn.request)
        or (type(http) == "table" and type(http.request) == "function" and http.request)
        or (type(fluxus) == "table" and type(fluxus.request) == "function" and fluxus.request)
end

-- Rarity Info & Database
local tiers = { common = 1, uncommon = 2, rare = 3, legendary = 4, mythical = 5 }

local RARITY_DATA = {
    [5] = { name = "Mythical",  badge = "🔴 Mythical",  color = 16711765 },
    [4] = { name = "Legendary", badge = "🟣 Legendary", color = 10696174 },
    [3] = { name = "Rare",      badge = "🔵 Rare",      color = 3447003 },
    [2] = { name = "Uncommon",  badge = "🟢 Uncommon",  color = 65332 },
    [1] = { name = "Common",    badge = "⚪ Common",    color = 9807270 },
    [0] = { name = "Unknown",   badge = "⚪ Unknown",   color = 16776960 },
}

local fallbackTiers = {
    -- Mythical (Cấp 5)
    kitsune = 5, dragon = 5, leopard = 5, ["t-rex"] = 5, trex = 5,
    mammoth = 5, dough = 5, shadow = 5, venom = 5, control = 5,
    spirit = 5, gravity = 5, gas = 5, hellfire = 5, yeti = 5,

    -- Legendary (Cấp 4)
    portal = 4, blizzard = 4, rumble = 4, buddha = 4, sound = 4,
    phoenix = 4, spider = 4, string = 4, love = 4, pain = 4,
    paw = 4, quake = 4,

    -- Rare (Cấp 3)
    magma = 3, ghost = 3, rubber = 3, light = 3, barrier = 3,

    -- Uncommon (Cấp 2)
    diamond = 2, dark = 2, sand = 2, ice = 2, falcon = 2, flame = 2,

    -- Common (Cấp 1)
    spike = 1, smoke = 1, bomb = 1, spring = 1, blade = 1,
    spin = 1, rocket = 1, chop = 1,
}

local fruitInfoList = nil
task.spawn(function()
    local module = RS:WaitForChild("FruitInfo", 5)
    local ok, data = pcall(function() return module and require(module) end)
    if ok and type(data) == "table" and type(data.List) == "table" then
        fruitInfoList = data.List
    end
end)

local function fruitIdentity(value)
    local name = string.lower(tostring(value or "")):gsub("^%s+", ""):gsub("%s+$", "")
    name = name:gsub("%s+fruit$", "")
    name = name:gsub("[%(%)]", ""):gsub("%s+", " ")
    for separator = 1, #name do
        if string.sub(name, separator, separator) == "-" then
            local left, right = string.sub(name, 1, separator - 1), string.sub(name, separator + 1)
            if left ~= "" and left == right then return left end
        end
    end
    return name
end

local function getFruitOriginalName(item)
    if not item then return nil end
    local ok, value = pcall(function() return item:GetAttribute("OriginalName") end)
    if ok and type(value) == "string" and value ~= "" then return value end
    local child = item:FindFirstChild("OriginalName")
    if child and child:IsA("StringValue") and child.Value ~= "" then return child.Value end
    return nil
end

-- Nhận diện Tool có phải là Trái Ác Quỷ hay không (chuẩn xác, không bỏ sót khi cầm trên tay)
local function isFruitTool(item)
    if not item or not item:IsA("Tool") then return false end

    -- 1. Kiểm tra ToolTip (Blox Fruits đặt ToolTip cho vũ khí / trái)
    local toolTip = string.lower(tostring(item.ToolTip or ""))
    if toolTip:find("sword") or toolTip:find("gun") or toolTip:find("melee") or toolTip:find("fighting") then
        return false
    end
    if toolTip:find("fruit") then
        return true
    end

    -- 2. Kiểm tra tên Tool
    local rawName = tostring(item.Name or "")
    local name = string.lower(rawName)
    if name:find("fruit", 1, true) then
        return true
    end

    -- 3. Kiểm tra OriginalName
    if item:GetAttribute("OriginalName") ~= nil then
        return true
    end
    local origVal = item:FindFirstChild("OriginalName")
    if origVal and origVal:IsA("StringValue") and origVal.Value ~= "" then
        return true
    end

    -- 4. Kiểm tra dạng hyphenated như "Rocket-Rocket", "Magma-Magma"
    if name:find("-", 1, true) then
        local id = fruitIdentity(name)
        if fallbackTiers[id] ~= nil or id ~= name then
            return true
        end
    end

    -- 5. Kiểm tra danh sách tên trái Blox Fruits
    local id = fruitIdentity(name)
    if fallbackTiers[id] ~= nil then
        return true
    end

    return false
end

local function getFruitRarity(name, storageName)
    local wanted = fruitIdentity(storageName or name)
    if type(fruitInfoList) == "table" then
        for key, row in pairs(fruitInfoList) do
            if type(key) == "string" and fruitIdentity(key) == wanted and type(row) == "table" then
                local rarity = type(row.Rarity) == "table" and row.Rarity.Name or row.Rarity
                if type(rarity) == "string" and tiers[rarity:lower()] then
                    local level = tiers[rarity:lower()]
                    return level, RARITY_DATA[level] or RARITY_DATA[0]
                end
            end
        end
    end

    local fallbackLevel = fallbackTiers[wanted]
    if not fallbackLevel then
        for key, level in pairs(fallbackTiers) do
            if wanted:find(key, 1, true) then
                fallbackLevel = level
                break
            end
        end
    end
    local level = fallbackLevel or 0
    return level, RARITY_DATA[level] or RARITY_DATA[0]
end

-- Bộ điều khiển & Hàng đợi
local controller = {
    Alive = true,
    Config = config,
}

local queue = {}
local seenTools = setmetatable({}, { __mode = "k" })
local seenStrings = {}
local connections = {}

-- Làm sạch cache chuỗi định kỳ
task.spawn(function()
    while controller.Alive do
        task.wait(10)
        local now = os.clock()
        for k, expire in pairs(seenStrings) do
            if now > expire then seenStrings[k] = nil end
        end
    end
end)

local function getWebhookUrl()
    local url = tostring(env.WebhookURL or config.WebhookURL or ""):match("^%s*(.-)%s*$")
    return url
end

function controller.Send(eventType, fruitName, tool, storageName)
    if not controller.Alive or not config.Enabled then return end

    if (eventType == "Holding" or eventType == "Held" or eventType == "Equipped") and not config.OnHolding then return end
    if eventType == "Picked" and not config.OnPickup then return end
    if eventType == "Random" and not config.OnRandom then return end
    if eventType == "Stored" and not config.OnStore then return end

    local url = getWebhookUrl()
    if url == "" then
        log("WARN", "Chua cau hinh WebhookURL! Vui long dat getgenv().WebhookURL = 'https://discord.com/api/webhooks/...'")
        return
    end
    if not url:match("^https://") then
        log("ERROR", "Webhook URL phai bat dau bang https://")
        return
    end

    local cleanName = tostring(fruitName or (tool and tool.Name) or "Unknown Fruit"):gsub("^%s+", ""):gsub("%s+$", "")
    local realStorage = storageName or (tool and getFruitOriginalName(tool))
    local level, rarityInfo = getFruitRarity(cleanName, realStorage)

    -- Bộ lọc chỉ định trái mục tiêu (Ví dụ: Hellfire / Gas Fruit)
    local targetFruit = tostring(env.WebhookOnlyFruit or env.OnlyFruit or config.OnlyFruit or ""):lower():match("^%s*(.-)%s*$")
    if targetFruit ~= "" and targetFruit ~= "all" then
        local fName = cleanName:lower()
        local sName = tostring(realStorage or ""):lower()
        local id = fruitIdentity(cleanName):lower()
        local sId = fruitIdentity(realStorage or ""):lower()
        local isMatch = false

        if targetFruit:find("gas") or targetFruit:find("hellfire") then
            isMatch = (fName:find("gas", 1, true) ~= nil or fName:find("hellfire", 1, true) ~= nil)
                or (sName:find("gas", 1, true) ~= nil or sName:find("hellfire", 1, true) ~= nil)
                or (id:find("gas", 1, true) ~= nil or id:find("hellfire", 1, true) ~= nil)
                or (sId:find("gas", 1, true) ~= nil or sId:find("hellfire", 1, true) ~= nil)
        else
            isMatch = (fName:find(targetFruit, 1, true) ~= nil)
                or (sName:find(targetFruit, 1, true) ~= nil)
                or id == targetFruit or sId == targetFruit
        end

        if not isMatch then
            log("FILTER", string.format("Bo qua trai '%s' vi chi nhan thong bao cho trai muc tieu: '%s'", cleanName, targetFruit))
            return
        end
    end

    -- Bộ lọc cấp bậc (MinRarity)
    local minRarity = tostring(env.WebhookMinRarity or config.MinRarity or "All"):lower():match("^%s*(.-)%s*$")
    local threshold = 0
    if minRarity == "mythical" then
        threshold = 5
    elseif minRarity == "legendary" then
        threshold = 4
    elseif minRarity == "rare" then
        threshold = 3
    elseif minRarity == "uncommon" then
        threshold = 2
    elseif minRarity == "common" then
        threshold = 1
    elseif minRarity == "all" then
        threshold = 0
    end

    if level < threshold then
        log("FILTER", string.format("Bo qua trai '%s' (%s, cap %d) vi duoi muc MinRarity '%s'. Dat getgenv().WebhookMinRarity = 'All' neu muon nhan moi trai.", cleanName, rarityInfo.name, level, minRarity))
        return
    end

    -- Chống spam trùng lặp cho Tool hoặc tên trái
    if tool then
        seenTools[tool] = seenTools[tool] or {}
        if seenTools[tool][eventType] then return end
        seenTools[tool][eventType] = true
    else
        local dedupeKey = string.format("%s:%s", tostring(eventType), cleanName)
        if seenStrings[dedupeKey] and os.clock() < seenStrings[dedupeKey] then
            return
        end
        seenStrings[dedupeKey] = os.clock() + 5
    end

    if #queue >= 50 then
        log("WARN", "Hang doi Webhook day; bo qua thong bao moi")
        return
    end

    local titles = {
        Holding = "Holding Fruit (Trên tay)",
        Held = "Holding Fruit (Trên tay)",
        Equipped = "Holding Fruit (Trên tay)",
        Picked = "Picked Fruit",
        Random = "Random Fruit",
        Stored = "Stored Fruit",
    }
    local eventTitle = titles[eventType] or (tostring(eventType) .. " Fruit")
    local embedColor = config.Color or rarityInfo.color or 16776960

    local embed = {
        title = config.Title,
        description = "**Main Status**\nUsername : ||" .. player.Name .. "||",
        color = embedColor,
        footer = { text = config.FooterText },
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        fields = {
            { name = eventTitle, value = "```\n" .. cleanName .. "\n```", inline = false },
            { name = "Rarity", value = rarityInfo.badge, inline = true },
            { name = "Username", value = "||" .. player.Name .. "||", inline = true },
            { name = "Time", value = os.date("%Y-%m-%d %H:%M:%S"), inline = true },
            { name = "PlaceId", value = tostring(game.PlaceId), inline = true },
        },
    }

    local banner = tostring(config.BannerURL or ""):match("^%s*(.-)%s*$")
    if banner:match("^https://") then
        embed.thumbnail = { url = banner }
    end

    local pingContent = env.WebhookPing ~= nil and tostring(env.WebhookPing) or config.Ping
    if pingContent == nil or (pingContent == "" and config.Ping ~= "") then
        pingContent = config.Ping
    end
    pingContent = tostring(pingContent or ""):match("^%s*(.-)%s*$")

    local payload = {
        content = pingContent,
        username = config.Username,
        embeds = { embed },
        allowed_mentions = { parse = { "everyone", "users", "roles" } },
    }

    local avatar = tostring(config.AvatarURL or ""):match("^%s*(.-)%s*$")
    if avatar:match("^https://") then
        payload.avatar_url = avatar
    end

    log("QUEUE", string.format("Them vao hang doi [%s]: %s (%s)", eventType, cleanName, rarityInfo.badge))
    table.insert(queue, { url = url, payload = payload, eventType = eventType, fruitName = cleanName })
end

-- Vòng lặp gửi Webhook định kỳ (0.5s/request)
task.spawn(function()
    while controller.Alive do
        task.wait(0.5)
        if not controller.Alive then break end

        local entry = table.remove(queue, 1)
        if entry then
            local requestFn = getHttpRequest()
            if type(requestFn) ~= "function" then
                log("ERROR", "Executor khong ho tro HTTP request")
            else
                local encodeOk, jsonBody = pcall(function()
                    return HttpService:JSONEncode(entry.payload)
                end)

                if encodeOk and jsonBody then
                    local ok, response = pcall(function()
                        return requestFn({
                            Url = entry.url,
                            Method = "POST",
                            Headers = { ["Content-Type"] = "application/json" },
                            Body = jsonBody,
                        })
                    end)

                    local code = type(response) == "table" and tonumber(response.StatusCode or response.Status or response.status_code)
                    if ok and code and code >= 200 and code < 300 then
                        log("SUCCESS", string.format("Da gui thong bao [%s]: %s thanh cong", entry.eventType, entry.fruitName))
                    else
                        log("WARN", string.format("Gui loi [%s] (code: %s)", entry.eventType, tostring(code or "nil")))
                    end
                else
                    log("ERROR", "Loi ma hoa JSON cho payload")
                end
            end
        end
    end
end)

-- =====================================================================
-- HỆ THỐNG AUTO STORE TRÁI VÀO RƯƠNG CỰC NHANH (FAST AUTO STORE)
-- =====================================================================
local storeInProgress = setmetatable({}, { __mode = "k" })
local storeAttempts = setmetatable({}, { __mode = "k" })
local ignoredStoreTools = setmetatable({}, { __mode = "k" })

local function getCommF()
    local remotes = RS:FindFirstChild("Remotes")
    return remotes and remotes:FindFirstChild("CommF_")
end

local function isStillOwned(tool)
    if not tool or not tool.Parent then return false end
    local bp = player:FindFirstChildOfClass("Backpack")
    local char = player.Character
    return (bp and tool:IsDescendantOf(bp)) or (char and tool:IsDescendantOf(char))
end

local function getFruitStorageName(item)
    if not item then return nil end
    local orig = getFruitOriginalName(item)
    if orig and orig ~= "" then return orig end

    local clean = tostring(item.Name or ""):gsub("%s+[Ff][Rr][Uu][Ii][Tt]$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean ~= "" then
        return clean .. "-" .. clean
    end
    return nil
end

local function tryStoreFruit(tool)
    if not config.AutoStore then return end
    if not tool or not isFruitTool(tool) then return end
    if ignoredStoreTools[tool] or storeInProgress[tool] then return end

    local attempts = (storeAttempts[tool] or 0) + 1
    storeAttempts[tool] = attempts

    if attempts > config.MaxStoreAttempts then
        ignoredStoreTools[tool] = true
        log("STORE", string.format("Bo qua hoan toan trai '%s' (da vuot qua %d lan thu)", tool.Name, config.MaxStoreAttempts))
        return
    end

    local commF = getCommF()
    if not commF then
        log("STORE_ERR", "Khong tim thay Remotes.CommF_ de luu trai")
        return
    end

    local storageName = getFruitStorageName(tool)
    if not storageName then
        log("STORE_ERR", "Chua xac dinh duoc StorageName cho " .. tool.Name)
        return
    end

    storeInProgress[tool] = true

    task.spawn(function()
        local toolName = tool.Name
        log("STORE", string.format("⚡ Dang luu '%s' vao ruong (Lan %d/%d)...", toolName, attempts, config.MaxStoreAttempts))

        -- Nếu trái đang cầm trên tay, unequip về balo để Remote StoreFruit luôn thành công
        if tool.Parent == player.Character and player.Character:FindFirstChildOfClass("Humanoid") then
            pcall(function() player.Character:FindFirstChildOfClass("Humanoid"):UnequipTools() end)
            task.wait(0.05)
        end

        -- Gửi remote StoreFruit ngay lập tức
        local ok, res = pcall(function()
            return commF:InvokeServer("StoreFruit", storageName, tool)
        end)

        -- Kiểm tra cực nhanh (mỗi 0.05s, tối đa 0.3s) xem Tool đã vào rương chưa
        local storedConfirmed = false
        for _ = 1, 6 do
            if not isStillOwned(tool) then
                storedConfirmed = true
                break
            end
            task.wait(0.05)
        end

        storeInProgress[tool] = nil

        if storedConfirmed then
            log("SUCCESS", string.format("✅ Da luu '%s' vao ruong thanh cong!", toolName))
            controller.Send("Stored", toolName, tool, storageName)
        else
            log("WARN", string.format("❌ Luu '%s' that bai (Lan %d/%d)", toolName, attempts, config.MaxStoreAttempts))
            if attempts >= config.MaxStoreAttempts then
                ignoredStoreTools[tool] = true
                log("STORE", string.format("⛔ Bo qua hoan toan trai '%s' sau %d lan thu that bai (kho day hoac da co)!", toolName, config.MaxStoreAttempts))
            else
                -- Thử lại cực nhanh sau StoreRetryDelay (0.3s)
                task.delay(config.StoreRetryDelay, function()
                    if controller.Alive and isStillOwned(tool) and not ignoredStoreTools[tool] then
                        tryStoreFruit(tool)
                    end
                end)
            end
        end
    end)
end

-- Tự động bắt sự kiện khi chạy độc lập (Standalone AutoDetect)
local function setupAutoDetect()
    if not config.AutoDetect then return end

    local function isNearGacha()
        local char = player.Character
        local root = char and char:FindFirstChild("HumanoidRootPart")
        if not root then return false end

        -- Kiểm tra NPC Blox Fruit Gacha / Cousin
        for _, npc in ipairs(workspace:GetDescendants()) do
            if npc:IsA("Model") and (npc.Name:find("Gacha") or npc.Name:find("Cousin")) then
                local part = npc:FindFirstChild("HumanoidRootPart") or npc:FindFirstChildWhichIsA("BasePart")
                if part and (part.Position - root.Position).Magnitude <= 60 then
                    return true
                end
            end
        end
        return false
    end

    local handledInstances = setmetatable({}, { __mode = "k" })

    local function handleFruitFound(tool, isHand)
        if not isFruitTool(tool) then return end

        local eventType = isHand and "Holding" or (isNearGacha() and "Random" or "Picked")

        -- Tránh thông báo trùng lặp cho cùng một Tool instance và eventType
        handledInstances[tool] = handledInstances[tool] or {}
        if not handledInstances[tool][eventType] then
            handledInstances[tool][eventType] = true

            task.delay(0.1, function()
                if not controller.Alive or not tool:IsDescendantOf(game) then return end
                controller.Send(eventType, tool.Name, tool, getFruitOriginalName(tool))
            end)
        end

        -- Tự động cất trái vào rương càng nhanh càng tốt
        if config.AutoStore and not ignoredStoreTools[tool] and not storeInProgress[tool] then
            task.spawn(tryStoreFruit, tool)
        end
    end

    local function scanAndListen(container, isHand)
        if not container then return end

        -- Quét tất cả Tool hiện có trong container (Bao gồm TRÁI ĐANG CẦM TRÊN TAY)
        for _, item in ipairs(container:GetChildren()) do
            if isFruitTool(item) then
                handleFruitFound(item, isHand)
            end
        end

        -- Lắng nghe khi có Tool mới được thêm vào (Equip vào tay hoặc nhặt vào backpack)
        local conn = container.ChildAdded:Connect(function(child)
            handleFruitFound(child, isHand)
        end)
        table.insert(connections, conn)
    end

    -- 1. Quét và lắng nghe Backpack
    local function bindBackpack(bp)
        if not bp then return end
        scanAndListen(bp, false)
    end

    bindBackpack(player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 5))
    local bpConn = player.ChildAdded:Connect(function(child)
        if child:IsA("Backpack") then
            bindBackpack(child)
        end
    end)
    table.insert(connections, bpConn)

    -- 2. Quét và lắng nghe Character (Trái đang cầm trên tay)
    local function bindCharacter(char)
        if not char then return end
        scanAndListen(char, true)
    end

    if player.Character then
        bindCharacter(player.Character)
    end

    local charConn = player.CharacterAdded:Connect(function(char)
        bindCharacter(char)
    end)
    table.insert(connections, charConn)

    -- 3. Polling kiểm tra dự phòng (Polling Ticker)
    -- Đảm bảo không bao giờ bỏ sót trái trên tay kể cả khi executor bắt sự kiện ChildAdded bị chậm hoặc lag
    task.spawn(function()
        while controller.Alive do
            task.wait(1)
            if not controller.Alive then break end

            -- Kiểm tra trái trên tay (Character)
            local char = player.Character
            if char then
                for _, item in ipairs(char:GetChildren()) do
                    if isFruitTool(item) then
                        handledInstances[item] = handledInstances[item] or {}
                        if not handledInstances[item]["Holding"] then
                            handleFruitFound(item, true)
                        elseif config.AutoStore and not ignoredStoreTools[item] and not storeInProgress[item] then
                            tryStoreFruit(item)
                        end
                    end
                end
            end

            -- Kiểm tra trái trong Backpack
            local bp = player:FindFirstChildOfClass("Backpack")
            if bp then
                for _, item in ipairs(bp:GetChildren()) do
                    if isFruitTool(item) then
                        handledInstances[item] = handledInstances[item] or {}
                        if not handledInstances[item]["Picked"] and not handledInstances[item]["Random"] then
                            handleFruitFound(item, false)
                        elseif config.AutoStore and not ignoredStoreTools[item] and not storeInProgress[item] then
                            tryStoreFruit(item)
                        end
                    end
                end
            end
        end
    end)
end

setupAutoDetect()

function controller.Stop()
    controller.Alive = false
    for _, conn in ipairs(connections) do
        pcall(function() conn:Disconnect() end)
    end
    table.clear(connections)
    table.clear(queue)
    if env.FruitWebhookController == controller then
        env.FruitWebhookController = nil
    end
    if env.FruitWebhookNotifier == controller then
        env.FruitWebhookNotifier = nil
    end
    log("INFO", "Da dung FruitWebhookNotifier")
end

function controller.Start()
    if not controller.Alive then
        controller.Alive = true
        setupAutoDetect()
        log("INFO", "Da khoi dong lai FruitWebhookNotifier")
    end
end

function controller.GetQueueCount()
    return #queue
end

-- Xuất biến toàn cục để các script khác (EvenMagnetFarm, v.v.) gọi trực tiếp
controller.StoreFruit = tryStoreFruit
controller.GetIgnoredFruits = function() return ignoredStoreTools end
env.StoreFruit = tryStoreFruit
env.SendFruitWebhook = function(eventType, fruitName, tool, storageName)
    controller.Send(eventType, fruitName, tool, storageName)
end
env.FruitWebhookNotifier = controller
env.FruitWebhookController = controller

log("INFO", string.format("FruitWebhook da san sang. Muc tieu: '%s' | AutoStore: %s (Max %d lan thu) | MinRarity: '%s'. Dang quet trai...", tostring(env.WebhookOnlyFruit or config.OnlyFruit), tostring(config.AutoStore and "ON" or "OFF"), config.MaxStoreAttempts, tostring(env.WebhookMinRarity or config.MinRarity)))

return controller
