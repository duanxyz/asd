-- NOTE: Bootstrap skeleton untuk rekonstruksi incremental skrip Auto Fishing

-- NOTE: Layanan inti dikumpulkan sekali agar modul lain tidak berulang panggil
local Services = {
    Players = game:GetService("Players"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    RunService = game:GetService("RunService"),
    HttpService = game:GetService("HttpService"),
    TeleportService = game:GetService("TeleportService"),
    LogService = game:GetService("LogService"),
    Lighting = game:GetService("Lighting"),
}

local LocalPlayer = Services.Players.LocalPlayer or Services.Players.PlayerAdded:Wait()
local Root = {
    Packages = Services.ReplicatedStorage:FindFirstChild("Packages"),
    Modules = Services.ReplicatedStorage:FindFirstChild("Modules"),
}

-- NOTE: Status global fitur ditempatkan di satu wadah supaya mudah diinspeksi
local state = {
    autoFish = false,
    autoSell = false,
    autoFavourite = false,
}

-- NOTE: Flag kanal notifikasi -> false berarti diam
local Notifs = {
    info = true,
    success = true,
    warning = true,
    error = true,
}

local function debugLog(...)
    warn("[FishIt]", ...)
end

local function assertService(value, name)
    if value then
        return value
    end

    debugLog(string.format("Service %s belum tersedia", name))
    return nil
end

assertService(LocalPlayer, "Players.LocalPlayer")
assertService(Root.Packages, "ReplicatedStorage.Packages")
assertService(Root.Modules, "ReplicatedStorage.Modules")

-- NOTE: Adapter notifikasi bersifat pluggable agar bisa diganti WindUI/dsb
local NotifyAdapters = {}

local function registerNotifyAdapter(kind, adapter)
    NotifyAdapters[kind] = adapter
end

local function notify(kind, title, message, duration)
    if Notifs[kind] == false then
        return
    end

    local adapter = NotifyAdapters[kind]
    if adapter then
        adapter(title, message, duration)
        return
    end

    debugLog(string.format("[%s] %s :: %s", kind:upper(), title or "", message or ""))
end

local MessageTypeAlias = {
    warning = Enum.MessageType.MessageWarning,
    info = Enum.MessageType.MessageInfo,
    error = Enum.MessageType.MessageError,
}

local function captureLog(levelKey)
    local enumItem = MessageTypeAlias[levelKey]
    if not enumItem then
        debugLog("MessageType tidak dikenal:", levelKey)
        return
    end

    Services.LogService.MessageOut:Connect(function(msg, msgType)
        if msgType == enumItem then
            if string.find(msg, "[FishIt]") then
                return
            end
            warn(msg)
        end
    end)
end

local function buildAnimationCatalog()
    local catalog = {
        RodIdle = {
            name = "ReelingIdle",
            assetId = "rbxassetid://134965425664034",
        },
        EquipIdle = {
            name = "EquipIdle",
            assetId = "rbxassetid://96586569072385",
        },
        RodCharge = {
            name = "LoopedRodCharge",
            assetId = "rbxassetid://137429009359442",
        },
        RodReel = {
            name = "ReelStart",
            assetId = "rbxassetid://136614469321844",
        },
        RodIntermission = {
            name = "ReelIntermission",
            assetId = "rbxassetid://114959536562596",
        },
    }

    local function loadAnimation(id)
        local meta = catalog[id]
        if not meta then
            debugLog("Animasi tidak dikenal:", id)
            return nil
        end

        local target = Services.ReplicatedStorage:FindFirstChild(meta.name, true)
        if target and target:IsA("Animation") then
            return target
        end

        if meta.assetId then
            local fallback = Instance.new("Animation")
            fallback.AnimationId = meta.assetId
            -- NOTE: Fallback dipakai kalau animasi tidak direplikasi
            debugLog("Fallback AnimationId untuk", id, meta.assetId)
            return fallback
        end

        debugLog("Gagal memuat animasi:", id)
        return nil
    end

    return setmetatable({}, {
        __index = function(_, key)
            return loadAnimation(key)
        end,
    })
end

local AnimationCatalog = buildAnimationCatalog()

local function ensureAnimator()
    local character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
    local humanoid = character:WaitForChild("Humanoid")
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end
    return animator
end

local function loadTrack(name)
    local animator = ensureAnimator()
    local animation = AnimationCatalog[name]
    if not animation then
        return nil
    end

    local success, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)

    if success then
        return track
    end

    debugLog("Gagal LoadAnimation untuk", name)
    return nil
end

-- NOTE: Track animasi disiapkan di awal supaya reuse dan gampang diberhentikan
local AnimTracks = {
    RodIdle = loadTrack("RodIdle"),
    RodCharge = loadTrack("RodCharge"),
    RodReel = loadTrack("RodReel"),
}

local function exposeDebugInterface()
    local ok, env = pcall(function()
        return getgenv and getgenv() or _G
    end)
    if not ok then
        return
    end

    env.FishItDebug = env.FishItDebug or {}
    env.FishItDebug.AnimTracks = AnimTracks
    -- NOTE: Helper agar bisa dites langsung via Command Bar
    env.FishItDebug.TestTracks = function()
        for name, track in pairs(AnimTracks) do
            if track then
                debugLog("Track", name, "OK")
                track:Play()
                task.delay(2, function()
                    track:Stop()
                end)
            else
                debugLog("Track", name, "MISS")
            end
        end
    end
end

exposeDebugInterface()

captureLog("warning") -- NOTE: Salin warning dari LogService ke Delta Console

notify("info", "Bootstrap", "Kerangka dasar siap", 3)

debugLog("Bootstrap selesai, siap lanjut ke tahap UI & fitur")

-- NOTE: Kolektor koneksi supaya fitur mudah dibersihkan
local connections = {}

local function disconnectAll()
    for index, conn in ipairs(connections) do
        if conn and conn.Disconnect then
            conn:Disconnect()
        end
        connections[index] = nil
    end
end

local function trackConnection(conn)
    table.insert(connections, conn)
    return conn
end

--[[
    FEATURE BLOCK: WindUI Loader
    ------------------------------------------------------------
    Referensi awal memakai WindUI, kita pertahankan dengan adaptor fallback.
]]

local UI = {
    loaded = false,
    window = nil,
    WindUI = nil,
    tabs = {},
}

local function loadWindUI()
    if UI.loaded then
        return true
    end

    local ok, module = pcall(function()
        return loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()
    end)

    if not ok then
        debugLog("WindUI gagal dimuat:", module)
        notify("warning", "WindUI", "Gagal muat WindUI, gunakan log console", 4)
        return false
    end

    UI.WindUI = module
    UI.loaded = true

    registerNotifyAdapter("info", function(title, message, duration)
        module:Notify({
            Title = title,
            Content = message,
            Duration = duration,
            Icon = "info",
        })
    end)

    registerNotifyAdapter("success", function(title, message, duration)
        module:Notify({
            Title = title,
            Content = message,
            Duration = duration,
            Icon = "circle-check",
        })
    end)

    registerNotifyAdapter("warning", function(title, message, duration)
        module:Notify({
            Title = title,
            Content = message,
            Duration = duration,
            Icon = "triangle-alert",
        })
    end)

    registerNotifyAdapter("error", function(title, message, duration)
        module:Notify({
            Title = title,
            Content = message,
            Duration = duration,
            Icon = "ban",
        })
    end)

    debugLog("WindUI berhasil dimuat")

    return true
end

local function buildWindow()
    if UI.window then
        return UI.window
    end

    if not loadWindUI() then
        return nil
    end

    local window = UI.WindUI:CreateWindow({
        Title = "FishIt Delta",
        Icon = "fish",
        Author = "FishIt Team",
        Folder = "FishItDelta",
        Size = UDim2.fromOffset(520, 420),
        Theme = "Indigo",
        KeySystem = false,
    })

    UI.window = window
    UI.WindUI:SetNotificationLower(true)
    window:SetToggleKey(Enum.KeyCode.G)

    notify("success", "FishIt", "UI siap digunakan", 3)

    UI.tabs.auto = window:Tab({
        Title = "Auto",
        Icon = "fish",
    })

    UI.tabs.utility = window:Tab({
        Title = "Utility",
        Icon = "widgets",
    })

    UI.tabs.settings = window:Tab({
        Title = "Settings",
        Icon = "sliders",
    })

    return window
end

local function ensureWindow()
    local window = buildWindow()
    if not window then
        debugLog("Window belum tersedia, WindUI gagal")
    end
    return window
end

--[[
    FEATURE BLOCK: Auto Fishing dasar
    ------------------------------------------------------------
    Mengadopsi logika referensi dengan penyesuaian agar modular.
]]

local Feature = {}

Feature.AutoFish = {
    rodTrack = AnimTracks,
    equipRemote = nil,
    chargeRemote = nil,
    miniGameRemote = nil,
    completeRemote = nil,
    rodDelay = 1.6,
    bypassDelay = 0.5,
    active = false,
}

function Feature.AutoFish:init()
    local packageIndex = assertService(Root.Packages and Root.Packages:FindFirstChild("_Index"), "Packages._Index")
    if not packageIndex then
        return false
    end

    local net = packageIndex:FindFirstChild("sleitnick_net@0.2.0")
    net = net and net:FindFirstChild("net")

    if not net then
        debugLog("Net package tidak ditemukan")
        return false
    end

    self.equipRemote = net:FindFirstChild("RE/EquipToolFromHotbar")
    self.chargeRemote = net:FindFirstChild("RF/ChargeFishingRod")
    self.miniGameRemote = net:FindFirstChild("RF/RequestFishingMinigameStarted")
    self.completeRemote = net:FindFirstChild("RE/FishingCompleted")

    if not (self.equipRemote and self.chargeRemote and self.miniGameRemote and self.completeRemote) then
        debugLog("Remote Auto Fish belum lengkap")
        return false
    end

    debugLog("AutoFish remote siap")
    return true
end

function Feature.AutoFish:getRodDelay()
    return self.rodDelay, self.bypassDelay
end

function Feature.AutoFish:setRodDelay(delay, bypass)
    if delay then
        self.rodDelay = delay
    end
    if bypass then
        self.bypassDelay = bypass
    end
end

function Feature.AutoFish:start()
    if self.active then
        return
    end

    if not self:init() then
        notify("error", "Auto Fish", "Remote tidak lengkap", 4)
        return
    end

    self.active = true
    state.autoFish = true

    notify("success", "Auto Fish", "Dinyalakan", 3)

    task.spawn(function()
        while self.active do
            local ok, err = pcall(function()
                self:cycle()
            end)

            if not ok then
                debugLog("AutoFish cycle error:", err)
                notify("warning", "Auto Fish", "Cycle error, cek console", 3)
                task.wait(1)
            end

            task.wait(0.1)
        end
    end)
end

function Feature.AutoFish:stop()
    if not self.active then
        return
    end

    self.active = false
    state.autoFish = false

    for _, track in pairs(self.rodTrack) do
        if track then
            track:Stop()
        end
    end

    notify("info", "Auto Fish", "Dimatikan", 3)
end

function Feature.AutoFish:cycle()
    local rodIdle = self.rodTrack.RodIdle
    local rodCharge = self.rodTrack.RodCharge
    local rodReel = self.rodTrack.RodReel

    local rodDelay, bypassDelay = self:getRodDelay()

    if rodIdle then
        rodIdle:Play()
    end

    if self.equipRemote then
        self.equipRemote:FireServer(1)
    end

    task.wait(0.15)

    if rodCharge then
        rodCharge:Play()
    end

    if self.chargeRemote then
        self.chargeRemote:InvokeServer(workspace:GetServerTimeNow())
    end

    task.wait(0.25)

    if rodReel then
        rodReel:Play()
    end

    if self.miniGameRemote then
        self.miniGameRemote:InvokeServer(-0.74 + math.random(-500, 500) / 10000000, 1)
    end

    task.wait(rodDelay)

    if self.completeRemote then
        self.completeRemote:FireServer()
        task.wait(bypassDelay)
        self.completeRemote:FireServer()
    end
end

local function buildAutoFishUI()
    if not ensureWindow() then
        return
    end

    local autoTab = UI.tabs.auto
    if not autoTab then
        debugLog("Auto tab belum siap")
        return
    end

    local section = autoTab:Section({
        Title = "Auto Fishing",
        Icon = "fish",
    })

    section:Toggle({
        Title = "Auto Fish",
        Content = "Mulai/stop siklus auto fishing",
        Callback = function(value)
            if value then
                Feature.AutoFish:start()
            else
                Feature.AutoFish:stop()
            end
        end,
    })

    section:Slider({
        Title = "Delay Rod",
        Content = "Sesuaikan delay utama (detik)",
        Min = 0.5,
        Max = 6,
        Default = Feature.AutoFish.rodDelay,
        Callback = function(value)
            Feature.AutoFish:setRodDelay(value, nil)
            notify("info", "Delay Rod", string.format("Delay %.2fs", value), 2)
        end,
    })

    section:Slider({
        Title = "Delay Bypass",
        Content = "Delay firing completion kedua",
        Min = 0.2,
        Max = 2,
        Default = Feature.AutoFish.bypassDelay,
        Callback = function(value)
            Feature.AutoFish:setRodDelay(nil, value)
            notify("info", "Delay Bypass", string.format("Delay %.2fs", value), 2)
        end,
    })
end

buildAutoFishUI()

notify("success", "FishIt", "Auto Fishing siap diuji", 4)
