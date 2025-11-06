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

-- NOTE: Cache untuk log sekali saja agar konsol tidak banjir
local debugOnceCache = {}

local function debugOnce(key, ...)
    if debugOnceCache[key] then
        return
    end
    debugOnceCache[key] = true
    debugLog(...)
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

local function getPackageIndex()
    local packages = Root.Packages
    if not packages then
        return nil
    end
    return packages:FindFirstChild("_Index")
end

local function findPackageByKeyword(keyword)
    local index = getPackageIndex()
    if not index then
        return nil
    end

    keyword = string.lower(keyword)
    for _, packageFolder in ipairs(index:GetChildren()) do
        if string.find(string.lower(packageFolder.Name), keyword, 1, true) then
            return packageFolder
        end
    end

    return nil
end

local function resolveNetFolder()
    local packageFolder = findPackageByKeyword("sleitnick_net")
    if not packageFolder then
        packageFolder = findPackageByKeyword("net@")
    end
    if not packageFolder then
        return nil
    end
    return packageFolder:FindFirstChild("net")
end

local function resolveReplionModule()
    local packageFolder = findPackageByKeyword("replion")
    if not packageFolder then
        return nil
    end

    local fallback
    for _, descendant in ipairs(packageFolder:GetDescendants()) do
        if descendant:IsA("ModuleScript") and string.lower(descendant.Name) == "replion" then
            return descendant
        end

        if descendant:IsA("ModuleScript") then
            local lowered = string.lower(descendant.Name)
            if lowered == "clientreplion" then
                return descendant
            end
            if lowered == "replion.init" or lowered == "replion_module" or lowered == "ytrev_replion" then
                fallback = descendant
            end
        end
    end

    return fallback
end

local function resolveItemUtilityModule()
    local modules = Root.Modules
    if not modules then
        return nil
    end

    local itemUtility = modules:FindFirstChild("ItemUtility", true)
    if itemUtility and itemUtility:IsA("ModuleScript") then
        return itemUtility
    end

    for _, descendant in ipairs(modules:GetDescendants()) do
        if descendant:IsA("ModuleScript") then
            local name = string.lower(descendant.Name)
            if name == "itemutility" or name == "item_util" or name == "itemstringutility" then
                return descendant
            end
        end
    end

    return nil
end

local function resolveFavouriteRemote()
    local net = resolveNetFolder()
    if not net then
        return nil
    end

    local direct = net:FindFirstChild("RE/FavoriteItem")
    if direct and direct:IsA("RemoteEvent") then
        return direct
    end

    for _, descendant in ipairs(net:GetDescendants()) do
        if descendant:IsA("RemoteEvent") then
            local lowered = string.lower(descendant.Name)
            if string.find(lowered, "favor") then
                return descendant
            end
        end
    end

    return nil
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
    local net = resolveNetFolder()
    if not net then
        debugOnce("net-missing", "Net package tidak ditemukan")
        return false
    end

    self.net = net
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

--[[
    FEATURE BLOCK: Auto Sell inventory (non favorit saja)
    ------------------------------------------------------------
]]

Feature.AutoSell = {
    running = false,
    threshold = 60,
    minInterval = 60,
    pollInterval = 10,
    lastSell = 0,
    net = nil,
    replion = nil,
    sellRemote = nil,
}

function Feature.AutoSell:init()
    if not self.net then
        self.net = resolveNetFolder()
    end

    if not self.net then
        debugOnce("autosell-net", "Auto Sell: net folder tidak ditemukan")
        return false
    end

    if not self.replion then
        local replionModule = resolveReplionModule()
        if not replionModule then
            debugOnce("autosell-replion-missing", "Auto Sell: modul Replion tidak ditemukan")
            return false
        end

        local ok, replionLib = pcall(require, replionModule)
        if not ok then
            debugOnce("autosell-replion-error", "Auto Sell: require Replion gagal", replionLib)
            return false
        end

        self.replion = replionLib
        debugOnce("autosell-replion-info", "Auto Sell: Replion module", replionModule:GetFullName())
    end

    if not self.sellRemote then
        self.sellRemote = self.net:FindFirstChild("RF/SellAllItems")
    end

    if not self.sellRemote then
        debugOnce("autosell-remote", "Auto Sell: remote RF/SellAllItems tidak ditemukan")
        return false
    end

    return true
end

function Feature.AutoSell:getInventoryItems()
    local replion = self.replion
    if not replion then
        debugOnce("autosell-client", "Auto Sell: Replion belum tersedia")
        return nil
    end

    local client = replion.Client
    if typeof(client) == "Instance" and client:IsA("ModuleScript") then
        local okRequire, required = pcall(require, client)
        if okRequire then
            client = required
            replion.Client = required
        else
            debugOnce("autosell-client-require", "Auto Sell: require Replion.Client gagal", required)
        end
    end

    if not client and replion.GetClient then
        local okCall, result = pcall(function()
            return replion:GetClient()
        end)
        if okCall then
            client = result
            replion.Client = result
        end
    end

    if type(client) ~= "table" or not client.WaitReplion then
        debugOnce("autosell-client", "Auto Sell: Replion Client tidak valid")
        return nil
    end

    local ok, result = pcall(function()
        local dataReplica = client:WaitReplion("Data")
        if dataReplica and dataReplica.Get then
            return dataReplica:Get({"Inventory", "Items"})
        end
        return nil
    end)

    if ok then
        return result
    end

    debugLog("Auto Sell: gagal ambil inventory", result)
    return nil
end

function Feature.AutoSell:computeUnfavoritedCount(items)
    local total = 0
    if type(items) ~= "table" then
        return total
    end

    local autoFav = Feature.AutoFavourite

    for _, item in ipairs(items) do
        if type(item) == "table" then
            local markedFavourite = false

            if autoFav and autoFav.running then
                local baseData = autoFav:getBaseData(item)
                if autoFav:shouldFavourite(item, baseData) then
                    markedFavourite = true
                    if not item.Favorited then
                        item.Favorited = true -- # NOTE: Sinkronisasi tanda favorit lokal agar Auto Sell menghormati kriteria Auto Favourite
                    end
                end
            end

            if not markedFavourite and not item.Favorited then
                total += item.Count or 1
            end
        end
    end

    return total
end

function Feature.AutoSell:invokeSell(count)
    if not self.sellRemote then
        return false
    end

    local ok, err = pcall(function()
        self.sellRemote:InvokeServer()
    end)

    if not ok then
        debugLog("Auto Sell: InvokeServer gagal", err)
        notify("error", "Auto Sell", "Penjualan gagal, cek console", 4)
        return false
    end

    notify("info", "Auto Sell", string.format("Menjual %d ikan non favorit", count), 4)
    return true
end

function Feature.AutoSell:tick()
    local items = self:getInventoryItems()
    if not items then
        return
    end

    local unfavoritedCount = self:computeUnfavoritedCount(items)
    if unfavoritedCount < self.threshold then
        return
    end

    local now = os.time()
    if now - self.lastSell < self.minInterval then
        return
    end

    if self:invokeSell(unfavoritedCount) then
        self.lastSell = now
    end
end

function Feature.AutoSell:start()
    if self.running then
        return
    end

    if not self:init() then
        notify("error", "Auto Sell", "Dependensi belum siap", 4)
        return
    end

    self.running = true
    state.autoSell = true

    notify("success", "Auto Sell", "Dinyalakan", 3)

    task.spawn(function()
        while self.running do
            local success, err = pcall(function()
                self:tick()
            end)

            if not success then
                debugLog("Auto Sell: tick error", err)
                notify("warning", "Auto Sell", "Tick error, cek console", 3)
                task.wait(1)
            end

            task.wait(self.pollInterval)
        end
    end)
end

function Feature.AutoSell:stop()
    if not self.running then
        return
    end

    self.running = false
    state.autoSell = false

    notify("info", "Auto Sell", "Dimatikan", 3)
end

--[[
    FEATURE BLOCK: Auto Favourite (rarity & mutasi)
    ------------------------------------------------------------
]]

Feature.AutoFavourite = {
    running = false,
    pollInterval = 5,
    raritySet = {
        secret = true,
        mythic = true,
        legendary = true,
    },
    mutationSet = {},
    mode = "rarity",
    replion = nil,
    itemUtility = nil,
    favouriteRemote = nil,
}

local extractMutationNames
local extractTier

local function exposeFeatureDebug()
    local ok, env = pcall(function()
        return getgenv and getgenv() or _G
    end)
    if not ok then
        return
    end

    env.FishItDebug = env.FishItDebug or {}
    env.FishItDebug.Features = Feature
    env.FishItDebug.DumpInventory = function()
        local items = Feature.AutoFavourite:getInventoryItems()
        if not items then
            debugLog("AutoFavourite", "Inventory tidak tersedia")
            return
        end

        for index, item in ipairs(items) do
            local mutations = extractMutationNames(item)
            local summary
            if Services.HttpService then
                local okEncode, encoded = pcall(function()
                    return Services.HttpService:JSONEncode(mutations)
                end)
                summary = okEncode and encoded or "<encode-failed>"
            else
                summary = "<no-httpservice>"
            end

            local tier = extractTier(item)
            debugLog("Inventory", index, item.Id or item.Name, tier or "<no-tier>", summary)
        end
    end
end

local function normalizeToken(token)
    if not token then
        return nil
    end
    token = string.gsub(token, "^%s+", "")
    token = string.gsub(token, "%s+$", "")
    if token == "" then
        return nil
    end
    return string.lower(token)
end

local function parseTokenList(text)
    local set = {}
    local pretty = {}

    if type(text) ~= "string" then
        return set, pretty
    end

    for token in string.gmatch(text, "[^,]+") do
        local normalized = normalizeToken(token)
        if normalized then
            set[normalized] = true
            table.insert(pretty, normalized)
        end
    end

    return set, pretty
end

function Feature.AutoFavourite:setRarityList(text)
    local set, pretty = parseTokenList(text)
    if next(set) == nil then
        notify("warning", "Auto Favourite", "Daftar rarity kosong, gunakan koma", 4)
        return
    end

    self.raritySet = set
    notify("info", "Auto Favourite", "Rarity aktif: " .. table.concat(pretty, ", "), 4)
end

function Feature.AutoFavourite:setMutationList(text)
    local set, pretty = parseTokenList(text)
    if next(set) == nil then
        notify("warning", "Auto Favourite", "Daftar mutasi kosong, gunakan koma", 4)
        return
    end

    self.mutationSet = set
    notify("info", "Auto Favourite", "Mutasi aktif: " .. table.concat(pretty, ", "), 4)
end

function Feature.AutoFavourite:resetRarity()
    self.raritySet = {
        secret = true,
        mythic = true,
        legendary = true,
    }

    notify("info", "Auto Favourite", "Rarity kembali ke default (Secret, Mythic, Legendary)", 4)
end

function Feature.AutoFavourite:resetMutation()
    self.mutationSet = {}
    notify("info", "Auto Favourite", "Daftar mutasi dikosongkan", 3)
end

function Feature.AutoFavourite:setMode(text)
    local normalized = normalizeToken(text)
    if not normalized then
        notify("warning", "Auto Favourite", "Mode tidak dikenal", 3)
        return
    end

    local aliases = {
        rarity = "rarity",
        tier = "rarity",
        tiers = "rarity",
        mutasi = "mutation",
        mutation = "mutation",
        mutasi_only = "mutation",
        kedua = "both",
        keduanya = "both",
        both = "both",
        gabungan = "both",
        kombinasi = "both",
        salahsatu = "either",
        ["salah-satu"] = "either",
        either = "either",
        any = "either",
    }

    local mode = aliases[normalized]
    if not mode then
        notify("warning", "Auto Favourite", "Mode tidak valid, gunakan: rarity/mutasi/keduanya/salah-satu", 4)
        return
    end

    self.mode = mode
    notify("info", "Auto Favourite", "Mode set ke " .. mode, 3)
end

function Feature.AutoFavourite:init()
    if not self.replion then
        if Feature.AutoSell and Feature.AutoSell.replion then
            self.replion = Feature.AutoSell.replion
        else
            local replionModule = resolveReplionModule()
            if replionModule then
                local ok, replionLib = pcall(require, replionModule)
                if ok then
                    self.replion = replionLib
                    debugOnce("autofav-replion-info", "Auto Favourite: Replion module tipe", typeof(replionLib))
                else
                    debugOnce("autofav-replion", "Auto Favourite: require Replion gagal", replionLib)
                end
            else
                debugOnce("autofav-replion-missing", "Auto Favourite: modul Replion tidak ditemukan")
            end
        end
    end

    if not self.replion then
        local okEnv, env = pcall(function()
            return getgenv and getgenv() or _G
        end)
        if okEnv and env and env.Replion then
            self.replion = env.Replion
            debugOnce("autofav-replion-global", "Auto Favourite: menggunakan global Replion")
        end
    end

    if not self.itemUtility then
        local itemUtilityModule = resolveItemUtilityModule()
        if itemUtilityModule then
            local ok, itemUtilityLib = pcall(require, itemUtilityModule)
            if ok then
                self.itemUtility = itemUtilityLib
            else
                debugOnce("autofav-itemutility", "Auto Favourite: require ItemUtility gagal", itemUtilityLib)
            end
        else
            debugOnce("autofav-itemutility-missing", "Auto Favourite: modul ItemUtility tidak ditemukan")
        end
    end

    if not self.replion then
        return false
    end

    if not self.favouriteRemote then
        self.favouriteRemote = resolveFavouriteRemote()
        if not self.favouriteRemote then
            debugOnce("autofav-remote-missing", "Auto Favourite: remote FavoriteItem tidak ditemukan")
        end
    end

    return true
end

function Feature.AutoFavourite:getInventoryItems()
    local replion = self.replion
    if not replion then
        debugOnce("autofav-client", "Auto Favourite: Replion belum tersedia")
        return nil
    end

    local client
    local rawClient = replion.Client

    if typeof(rawClient) == "Instance" and rawClient:IsA("ModuleScript") then
        local okRequire, result = pcall(require, rawClient)
        if okRequire then
            replion.Client = result
            rawClient = result
        else
            debugOnce("autofav-client-require", "Auto Favourite: require Replion.Client gagal", result)
        end
    end

    if type(rawClient) == "table" and rawClient.WaitReplion then
        client = rawClient
    elseif replion.GetClient then
        local okCall, result = pcall(function()
            return replion:GetClient()
        end)
        if okCall and type(result) == "table" and result.WaitReplion then
            client = result
            replion.Client = result
        end
    end

    if not client then
        debugOnce("autofav-client", "Auto Favourite: Replion Client tidak valid")
        return nil
    end

    local ok, result = pcall(function()
        local replica = client:WaitReplion("Data")
        if replica and replica.Get then
            return replica:Get({"Inventory", "Items"})
        end
        return nil
    end)

    if ok then
        return result
    end

    debugLog("Auto Favourite: gagal ambil inventory", result)
    return nil
end

extractMutationNames = function(item)
    local names = {}
    if type(item) ~= "table" then
        return names
    end

    local candidates = {
        item.Mutations,
        item.mutations,
        item.Mutation,
        item.mutation,
        item.BaseData and item.BaseData.Mutations,
        item.BaseData and item.BaseData.Data and item.BaseData.Data.Mutations,
        item.Metadata and item.Metadata.Mutations,
        item.ItemData and item.ItemData.Mutations,
    }

    for _, source in ipairs(candidates) do
        if type(source) == "table" then
            for _, mut in pairs(source) do
                local name
                if type(mut) == "string" then
                    name = mut
                elseif type(mut) == "table" then
                    name = mut.Name or mut.name or mut.Id or mut.id or mut.DisplayName or mut[1]
                end

                if name then
                    table.insert(names, string.lower(tostring(name)))
                end
            end
        end
    end

    return names
end

local function hasEntries(set)
    return set and next(set) ~= nil
end

extractTier = function(item, baseData)
    local candidates = {
        baseData and baseData.Data and baseData.Data.Tier,
        baseData and baseData.Tier,
        item.Tier,
        item.Rarity,
        item.tier,
        item.rarity,
        item.BaseData and item.BaseData.Tier,
        item.BaseData and item.BaseData.Data and item.BaseData.Data.Tier,
        item.ItemData and item.ItemData.Tier,
        item.Metadata and item.Metadata.Tier,
    }

    for _, value in ipairs(candidates) do
        if type(value) == "string" and value ~= "" then
            return string.lower(value)
        end
    end

    return nil
end

function Feature.AutoFavourite:getBaseData(item)
    if type(item) ~= "table" then
        return nil
    end

    if self.itemUtility and self.itemUtility.GetItemData and item.Id then
        local ok, data = pcall(self.itemUtility.GetItemData, self.itemUtility, item.Id)
        if ok and data then
            return data
        end
    end

    local sources = {
        item.ItemData,
        item.BaseData,
        item.Metadata,
    }

    for _, candidate in ipairs(sources) do
        if type(candidate) == "table" and next(candidate) ~= nil then
            return candidate
        end
    end

    return nil
end

function Feature.AutoFavourite:markFavourite(item)
    if type(item) ~= "table" then
        return
    end

    if item.Favorited then
        return
    end

    local uuid = item.UUID or item.Uuid or item.ItemUUID or item.ItemUuid or item.Id
    if not uuid then
        debugOnce("autofav-missing-uuid", "Auto Favourite: item tidak punya UUID/Id untuk favorit")
        return
    end

    if not self.favouriteRemote then
        self.favouriteRemote = resolveFavouriteRemote()
        if not self.favouriteRemote then
            debugOnce("autofav-remote-missing", "Auto Favourite: remote FavoriteItem tidak ditemukan")
            return
        end
    end

    local remote = self.favouriteRemote
    local ok, err = pcall(function()
        remote:FireServer(uuid) -- # NOTE: Sinkronisasi favorit ke server via RemoteEvent FavoriteItem
    end)

    if not ok then
        debugOnce("autofav-remote-error", "Auto Favourite: FavoriteItem FireServer gagal", err)
    end
end

function Feature.AutoFavourite:shouldFavourite(item, baseData)
    local matchesRarity = false
    local matchesMutation = false

    local tier = extractTier(item, baseData)
    if tier then
        matchesRarity = self.raritySet[tier] or false
    end

    if hasEntries(self.mutationSet) then
        local mutationNames = extractMutationNames(item)
        for _, name in ipairs(mutationNames) do
            if self.mutationSet[name] then
                matchesMutation = true
                break
            end
        end
    end

    if self.mode == "mutation" then
        return matchesMutation
    end

    if self.mode == "both" then
        if not hasEntries(self.mutationSet) then
            debugOnce("autofav-mode-mutation-empty", "Auto Favourite: mode 'both' tapi daftar mutasi kosong")
            return matchesRarity
        end
        return matchesRarity and matchesMutation
    end

    if self.mode == "either" then
        return matchesRarity or matchesMutation
    end

    -- default rarity
    return matchesRarity
end

function Feature.AutoFavourite:tick()
    local items = self:getInventoryItems()
    if not items then
        return
    end

    for _, item in ipairs(items) do
        local baseData = self:getBaseData(item)

        if not item.Favorited and self:shouldFavourite(item, baseData) then
            self:markFavourite(item)
            item.Favorited = true
        end
    end
end

function Feature.AutoFavourite:start()
    if self.running then
        return
    end

    if not self:init() then
        notify("error", "Auto Favourite", "Dependensi belum siap", 4)
        return
    end

    self.running = true
    state.autoFavourite = true

    notify("success", "Auto Favourite", "Dinyalakan", 3)

    task.spawn(function()
        while self.running do
            local success, err = pcall(function()
                self:tick()
            end)

            if not success then
                debugLog("Auto Favourite: tick error", err)
                notify("warning", "Auto Favourite", "Tick error, cek console", 3)
                task.wait(1)
            end

            task.wait(self.pollInterval)
        end
    end)
end

function Feature.AutoFavourite:stop()
    if not self.running then
        return
    end

    self.running = false
    state.autoFavourite = false

    notify("info", "Auto Favourite", "Dimatikan", 3)
end

exposeFeatureDebug()

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

    local function parseAndClamp(value, minValue, maxValue)
        local numberValue = tonumber(value)
        if numberValue == nil then
            return nil
        end

        if minValue ~= nil then
            numberValue = math.max(minValue, numberValue)
        end

        if maxValue ~= nil then
            numberValue = math.min(maxValue, numberValue)
        end

        return numberValue
    end

    section:Input({
        Title = "Delay Rod",
        Content = "Detik delay utama (0.5 - 6)",
        Placeholder = string.format("%.2f", Feature.AutoFish.rodDelay),
        Callback = function(value)
            local numberValue = parseAndClamp(value, 0.5, 6)
            if not numberValue then
                notify("warning", "Delay Rod", "Masukkan angka valid", 3)
                return
            end

            Feature.AutoFish:setRodDelay(numberValue, nil)
            notify("info", "Delay Rod", string.format("Delay %.2fs", numberValue), 2)
        end,
    })

    section:Input({
        Title = "Delay Bypass",
        Content = "Detik delay completion kedua (0.2 - 2)",
        Placeholder = string.format("%.2f", Feature.AutoFish.bypassDelay),
        Callback = function(value)
            local numberValue = parseAndClamp(value, 0.2, 2)
            if not numberValue then
                notify("warning", "Delay Bypass", "Masukkan angka valid", 3)
                return
            end

            Feature.AutoFish:setRodDelay(nil, numberValue)
            notify("info", "Delay Bypass", string.format("Delay %.2fs", numberValue), 2)
        end,
    })

    section:Toggle({
        Title = "Auto Sell",
        Content = "Jual otomatis ikan non favorit",
        Callback = function(value)
            if value then
                Feature.AutoSell:start()
            else
                Feature.AutoSell:stop()
            end
        end,
    })

    section:Input({
        Title = "Ambang Auto Sell",
        Content = "Ikan non favorit sebelum dijual (10 - 150)",
        Placeholder = tostring(Feature.AutoSell.threshold),
        Callback = function(value)
            local numberValue = parseAndClamp(value, 10, 150)
            if not numberValue then
                notify("warning", "Auto Sell", "Masukkan angka valid", 3)
                return
            end

            Feature.AutoSell.threshold = math.floor(numberValue)
            notify("info", "Auto Sell", string.format("Threshold %d ikan", Feature.AutoSell.threshold), 2)
        end,
    })

    section:Input({
        Title = "Jeda Penjualan",
        Content = "Jeda antar penjualan (detik) (15 - 180)",
        Placeholder = tostring(Feature.AutoSell.minInterval),
        Callback = function(value)
            local numberValue = parseAndClamp(value, 15, 180)
            if not numberValue then
                notify("warning", "Auto Sell", "Masukkan angka valid", 3)
                return
            end

            Feature.AutoSell.minInterval = math.floor(numberValue)
            notify("info", "Auto Sell", string.format("Jeda %ds", Feature.AutoSell.minInterval), 2)
        end,
    })

    local favouriteSection = autoTab:Section({
        Title = "Auto Favourite",
        Icon = "star",
    })

    favouriteSection:Paragraph({
        Title = "Proteksi Ikan Berharga",
        Content = "Tandai otomatis ikan berdasarkan rarity, mutasi, atau keduanya.",
    })

    favouriteSection:Toggle({
        Title = "Auto Favourite",
        Content = "Aktifkan penandaan otomatis",
        Callback = function(value)
            if value then
                Feature.AutoFavourite:start()
            else
                Feature.AutoFavourite:stop()
            end
        end,
    })

    favouriteSection:Input({
        Title = "Daftar Rarity",
        Content = "Pisahkan dengan koma (contoh: Secret, Mythic, Legendary)",
        Placeholder = "Secret, Mythic, Legendary",
        Callback = function(value)
            Feature.AutoFavourite:setRarityList(value)
        end,
    })

    favouriteSection:Input({
        Title = "Daftar Mutasi",
        Content = "Pisahkan dengan koma (contoh: Radiant, Glacial)",
        Placeholder = "Radiant, Glacial",
        Callback = function(value)
            Feature.AutoFavourite:setMutationList(value)
        end,
    })

    favouriteSection:Input({
        Title = "Mode Seleksi",
        Content = "rarity / mutasi / keduanya / salah-satu",
        Placeholder = "rarity",
        Callback = function(value)
            Feature.AutoFavourite:setMode(value)
        end,
    })

    favouriteSection:Button({
        Title = "Reset Kriteria",
        Content = "Kembalikan rarity default dan kosongkan mutasi",
        Callback = function()
            Feature.AutoFavourite:resetRarity()
            Feature.AutoFavourite:resetMutation()
        end,
    })
end

buildAutoFishUI()

notify("success", "FishIt", "Auto Fishing siap diuji", 4)
