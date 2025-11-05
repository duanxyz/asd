-- NOTE: Bootstrap skeleton untuk rekonstruksi incremental skrip Auto Fishing

local Services = {
    Players = game:GetService("Players"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    RunService = game:GetService("RunService"),
    HttpService = game:GetService("HttpService"),
    TeleportService = game:GetService("TeleportService"),
    Lighting = game:GetService("Lighting"),
}

local LocalPlayer = Services.Players.LocalPlayer or Services.Players.PlayerAdded:Wait()
local Root = {
    Packages = Services.ReplicatedStorage:FindFirstChild("Packages"),
    Modules = Services.ReplicatedStorage:FindFirstChild("Modules"),
}

local state = {
    autoFish = false,
    autoSell = false,
    autoFavourite = false,
}

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

notify("info", "Bootstrap", "Kerangka dasar siap", 3)

debugLog("Bootstrap selesai, siap lanjut ke tahap UI & fitur")
