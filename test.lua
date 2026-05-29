--[[
    AI Script v0.20
    Game: UGC Prison (Place ID: 102718061120016)
    v0.20: Trash farm rewritten with correct remotes (Prompt.Interact.Event).
           Deposit remote: Recyclement Room bin.
           Earnings counter for trash. Default bin position set.
           Spam head/blink button (UnreliableReplicationEvent).
           Infinite hunger/thirst auto-finds by name.
    v0.19: Auto trash collection. Staff alert blocks other sounds.
    v0.17: Removed SPY button. Default click delay 0.6s.
    v0.15: task.wait delay approach for pull-ups
]]

if getgenv and getgenv()._AILoaded then return end
if getgenv then getgenv()._AILoaded = true end

--// SHARED STATE
local S = {
    Players = game:GetService("Players"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    RunService = game:GetService("RunService"),
    VirtualUser = game:GetService("VirtualUser"),
    UserInputService = game:GetService("UserInputService"),
    Workspace = game:GetService("Workspace"),

    LocalPlayer = nil,
    Character = nil,
    Humanoid = nil,
    HumanoidRootPart = nil,

    CAVE_POS = Vector3.new(-424, -8, 246),
    MINING_DISTANCE = 5,
    HIT_INTERVAL = 0.45,
    SELL_THRESHOLD = 10,
    MINERAL_BUYER_NAME = "Mineral Buyer",
    ORE_PRICES = { Azurith = 54, RawGold = 24, RawIron = 11, RawCopper = 5, Coal = 4 },

    isFarming = false,
    farmStartTime = 0,
    frozenTimeStr = "00:00:00",
    frozenOreCount = 0,
    frozenEarnings = 0,
    totalOreMined = 0,
    totalEarnings = 0,
    currentSessionOre = 0,
    currentSessionEarnings = 0,
    minedRocks = {},
    lastRockPosition = nil,
    farmThread = nil,
    platformPart = nil,

    isFlying = false,
    flySpeed = 80,
    flyBodyVelocity = nil,
    flyBodyGyro = nil,
    flyConn = nil,

    isNoclipping = false,
    noclipConn = nil,

    isNoFallDmg = false,

    isInfiniteHunger = false,
    hungerConn = nil,

    antiAFKConn = nil,

    isInvisible = false,
    invisHeartbeatConn = nil,
    invisCharAddedConn = nil,

    awMatchActive = false,
    awCurrentRemote = nil,
    awAutoEnabled = false,
    awSuperFastMode = false,
    awNormalDelay = 0.10,
    awSuperFiresPF = 1,
    awSpamThread = nil,
    awSuperFastConn = nil,
    awTotalFires = 0,

    isPullUpActive = false,
    pullUpAutoClimb = false,
    pullUpClickConn = nil,
    pullUpMonitorThread = nil,
    pullUpClimbThread = nil,
    pullUpCycles = 0,
    pullUpOnBar = false,
    pullUpScore = 0,
    pullUpGameDuration = 60,
    pullUpClickDelay = 0.6,  -- seconds to wait after circle appears before clicking
    _pullUpListener = nil,
    pullUpClickedSet = {},   -- track which circles we've already scheduled

    -- Trash collection
    isTrashFarming = false,
    trashFarmThread = nil,
    trashBinPos = Vector3.new(-115.4, -54.3, -408.2),  -- Recyclement Room bin
    trashReturnPos = nil,       -- Vector3, return here after all trash collected
    trashCollected = 0,
    trashTotal = 0,
    trashEarnings = 0,
    trashSessionStartMoney = 0,

    -- Spam head/blink
    isSpammingHead = false,
    spamHeadConn = nil,

    keybinds = {},
    listeningForBind = nil,

    lastNotifTime = 0,
    NOTIF_COOLDOWN = 3,

    _isAlertPlaying = false,   -- staff alert sound playing flag

    Pages = {},
    Buttons = {},
}

S.LocalPlayer = S.Players.LocalPlayer
S.Character = S.LocalPlayer.Character or S.LocalPlayer.CharacterAdded:Wait()
S.Humanoid = S.Character:WaitForChild("Humanoid")
S.HumanoidRootPart = S.Character:WaitForChild("HumanoidRootPart")

--// ============================================================
--// UTILITY
--// ============================================================
do
    local function getCharacter()
        local char = S.LocalPlayer.Character
        if char and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") then
            return char
        end
        return nil
    end
    S.getCharacter = getCharacter

    function S.getHRP()
        local char = getCharacter()
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    function S.getHumanoid()
        local char = getCharacter()
        return char and char:FindFirstChildOfClass("Humanoid")
    end

    function S.getToolEvent()
        local remotes = S.ReplicatedStorage:FindFirstChild("Remotes")
        if not remotes then return nil end
        local toolFolder = remotes:FindFirstChild("Tool")
        if not toolFolder then return nil end
        return toolFolder:FindFirstChild("Event")
    end

    function S.getSellRemote()
        local remotes = S.ReplicatedStorage:FindFirstChild("Remotes")
        if not remotes then return nil end
        return remotes:FindFirstChild("SellOre")
    end

    function S.getMineralBuyer()
        local entities = S.Workspace:FindFirstChild("Entities")
        if not entities then return nil end
        return entities:FindFirstChild(S.MINERAL_BUYER_NAME)
    end

    function S.getRocksParent()
        local tasks = S.Workspace:FindFirstChild("Tasks")
        if not tasks then return nil end
        local prisoner = tasks:FindFirstChild("Prisoner")
        if not prisoner then return nil end
        return prisoner:FindFirstChild("Rocks")
    end

    function S.countInventoryItems()
        local char = getCharacter()
        local counts = {}
        for oreName, _ in pairs(S.ORE_PRICES) do counts[oreName] = 0 end
        local backpack = S.LocalPlayer:FindFirstChild("Backpack")
        if backpack then
            for _, item in ipairs(backpack:GetChildren()) do
                if S.ORE_PRICES[item.Name] then counts[item.Name] = counts[item.Name] + 1 end
            end
        end
        if char then
            for _, item in ipairs(char:GetChildren()) do
                if S.ORE_PRICES[item.Name] then counts[item.Name] = counts[item.Name] + 1 end
            end
        end
        return counts
    end

    function S.getTotalOreCount(inventory)
        local total = 0
        for _, count in pairs(inventory) do total = total + count end
        return total
    end

    function S.calculateEarnings(inventory)
        local total = 0
        for oreName, count in pairs(inventory) do
            if S.ORE_PRICES[oreName] then total = total + (count * S.ORE_PRICES[oreName]) end
        end
        return total
    end

    function S.formatTime(seconds)
        local h = math.floor(seconds / 3600)
        local m = math.floor((seconds % 3600) / 60)
        local s = math.floor(seconds % 60)
        return string.format("%02d:%02d:%02d", h, m, s)
    end
end

--// ============================================================
--// GAME NOTIFICATION
--// ============================================================
do
    function S.sendNotif(text)
        local now = tick()
        if now - S.lastNotifTime < S.NOTIF_COOLDOWN then return end
        S.lastNotifTime = now
        pcall(function()
            local notifRemote = S.ReplicatedStorage:FindFirstChild("Remotes")
                and S.ReplicatedStorage.Remotes:FindFirstChild("Notifications")
                and S.ReplicatedStorage.Remotes.Notifications:FindFirstChild("Event")
            if notifRemote and notifRemote:IsA("RemoteEvent") then
                firesignal(notifRemote.OnClientEvent, table.unpack({
                    [1] = text,
                    [2] = 3,
                }))
            end
        end)
    end

    function S.sendLongNotif(text, duration)
        pcall(function()
            local notifRemote = S.ReplicatedStorage:FindFirstChild("Remotes")
                and S.ReplicatedStorage.Remotes:FindFirstChild("Notifications")
                and S.ReplicatedStorage.Remotes.Notifications:FindFirstChild("Event")
            if notifRemote and notifRemote:IsA("RemoteEvent") then
                firesignal(notifRemote.OnClientEvent, table.unpack({
                    [1] = text,
                    [2] = duration or 20,
                }))
            end
        end)
    end
end

--// ============================================================
--// ROCK FINDING + PLATFORM
--// ============================================================
do
    function S.isRockValid(rock)
        if not rock then return false end
        if rock.Parent == nil then return false end
        if not S.Workspace:IsAncestorOf(rock) then return false end
        if not rock:IsA("BasePart") then return false end
        if rock:GetAttribute("Destroyed") == true then return false end
        local hp = rock:GetAttribute("HP") or rock:GetAttribute("Health")
        if hp == nil then return false end
        if type(hp) == "number" and hp <= 0 then return false end
        return true
    end

    function S.findNearestRock(skipList)
        skipList = skipList or {}
        local rocksParent = S.getRocksParent()
        if not rocksParent then return nil end
        local hrp = S.getHRP()
        if not hrp then return nil end
        local nearest = nil
        local nearestDist = math.huge
        for _, rock in ipairs(rocksParent:GetChildren()) do
            if rock:IsA("BasePart") and S.isRockValid(rock) then
                local skip = false
                for _, s in ipairs(skipList) do
                    if s == rock then skip = true; break end
                end
                if not skip then
                    local dist = (rock.Position - hrp.Position).Magnitude
                    if dist < nearestDist then
                        nearestDist = dist
                        nearest = rock
                    end
                end
            end
        end
        return nearest, nearestDist
    end

    function S.createPlatform(position)
        S.removePlatform()
        pcall(function()
            local p = Instance.new("Part")
            p.Name = "AIPlatform"
            p.Size = Vector3.new(12, 1, 12)
            p.Position = position - Vector3.new(0, 3, 0)
            p.Anchored = true
            p.CanCollide = true
            p.Transparency = 1
            p.Material = Enum.Material.SmoothPlastic
            p.Parent = S.Workspace
            S.platformPart = p
        end)
    end

    function S.removePlatform()
        if S.platformPart then
            pcall(function() S.platformPart:Destroy() end)
            S.platformPart = nil
        end
    end
end

--// ============================================================
--// ANTI-AFK
--// ============================================================
do
    function S.startAntiAFK()
        if S.antiAFKConn then return end
        S.antiAFKConn = S.LocalPlayer.Idled:Connect(function()
            S.VirtualUser:CaptureController()
            S.VirtualUser:ClickButton2(Vector2.new())
        end)
    end
end

--// ============================================================
--// HOOKMETAMETHOD: No Fall DMG + Block sounds during staff alert
--// ============================================================
-- Uses hookmetamethod to intercept __namecall:
--   1. Block DamageEvent:FireServer() when No Fall DMG is enabled.
--   2. Block Sound:Play() for non-alert sounds during staff alert.
-- The hook is always installed but only blocks when flags are on.
--//=============================================================
do
    local DamageEvent = S.ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("DamageEvent")
    local ALERT_SOUND_ID = "rbxassetid://132238052138705"
    local oldNamecall = nil

    -- Install the hook once (always active, checks flags internally)
    oldNamecall = hookmetamethod(game, "__namecall", newcclosure(function(self, ...)
        local method = getnamecallmethod()
        -- Block fall damage
        if method == "FireServer" and self == DamageEvent and S.isNoFallDmg then
            return
        end
        -- Block other sounds during staff alert (only allow our alert sound)
        if method == "Play" and S._isAlertPlaying then
            if typeof(self) == "Instance" and self:IsA("Sound") and self.SoundId ~= ALERT_SOUND_ID then
                return  -- Block this sound from playing during alert
            end
        end
        return oldNamecall(self, ...)
    end))

    function S.toggleNoFallDMG(enable)
        S.isNoFallDmg = enable and true or false
    end
end

--// ============================================================
--// NOCLIP
--// ============================================================
do
    function S.toggleNoclip(enable)
        if enable then
            if S.noclipConn then S.noclipConn:Disconnect() end
            S.noclipConn = S.RunService.Stepped:Connect(function()
                local char = S.getCharacter()
                if char then
                    for _, part in ipairs(char:GetDescendants()) do
                        if part:IsA("BasePart") then part.CanCollide = false end
                    end
                end
            end)
            S.isNoclipping = true
        else
            if S.noclipConn then S.noclipConn:Disconnect(); S.noclipConn = nil end
            S.isNoclipping = false
        end
    end
end

--// ============================================================
--// INVISIBILITY (Desync Teleport — exact method from open source)
--// Every Heartbeat: save CFrame → teleport HRP down 200k → set CameraOffset
--// → wait RenderStepped → restore CFrame and CameraOffset
--// Server sees you underground = invisible to other players.
--// Camera follows normally, movement works normally.
--//=============================================================
do
    local INVIS_OFFSET = Vector3.new(0, -200000, 0)

    local function setupCharacter()
        local char = S.LocalPlayer.Character or S.LocalPlayer.CharacterAdded:Wait()
        return char:WaitForChild("HumanoidRootPart", 5), char:WaitForChild("Humanoid", 5)
    end

    function S.toggleInvisibility(enable)
        if enable then
            local hrp, hum = setupCharacter()
            if not hrp or not hum then return end

            S.isInvisible = true

            -- Collect visible parts for transparency
            local VisibleParts = {}
            for _, descendant in pairs(hrp.Parent:GetDescendants()) do
                if descendant:IsA("BasePart") and descendant.Transparency == 0 then
                    table.insert(VisibleParts, descendant)
                end
            end
            -- Make parts semi-transparent on client (visual effect)
            for _, part in pairs(VisibleParts) do
                pcall(function() part.Transparency = 0.5 end)
            end

            -- ONE Heartbeat connection: teleport down → wait render → restore
            S.invisHeartbeatConn = S.RunService.Heartbeat:Connect(function()
                if not S.isInvisible then return end
                local c = S.LocalPlayer.Character
                if not c then return end
                local h = c:FindFirstChild("HumanoidRootPart")
                local hu = c:FindFirstChildOfClass("Humanoid")
                if not h or not hu then return end

                local OriginalCFrame = h.CFrame
                local OriginalCameraOffset = hu.CameraOffset

                -- Teleport HRP down 200k studs
                local DownCFrame = OriginalCFrame * CFrame.new(INVIS_OFFSET)
                h.CFrame = DownCFrame

                -- Compensate camera so it stays where it was
                hu.CameraOffset = DownCFrame:ToObjectSpace(CFrame.new(OriginalCFrame.Position)).Position

                -- Wait for render frame (server processes the "down" position)
                S.RunService.RenderStepped:Wait()

                -- Restore position and camera
                h.CFrame = OriginalCFrame
                hu.CameraOffset = OriginalCameraOffset
            end)

            -- Handle respawn while invisible
            if S.invisCharAddedConn then S.invisCharAddedConn:Disconnect() end
            S.invisCharAddedConn = S.LocalPlayer.CharacterAdded:Connect(function(newChar)
                if not S.isInvisible then return end
                -- Re-collect visible parts for new character
                newChar:WaitForChild("HumanoidRootPart", 5)
                newChar:WaitForChild("Humanoid", 5)
                task.wait(0.3)
                for _, descendant in pairs(newChar:GetDescendants()) do
                    if descendant:IsA("BasePart") and descendant.Transparency == 0 then
                        pcall(function() descendant.Transparency = 0.5 end)
                    end
                end
            end)

            S.sendNotif("Invisible: ON")
        else
            -- Stop heartbeat connection
            if S.invisHeartbeatConn then
                S.invisHeartbeatConn:Disconnect()
                S.invisHeartbeatConn = nil
            end

            -- Reset camera offset just in case
            local c = S.LocalPlayer.Character
            if c then
                local hu = c:FindFirstChildOfClass("Humanoid")
                if hu then
                    hu.CameraOffset = Vector3.new(0, 0, 0)
                end
                -- Restore transparency
                for _, descendant in pairs(c:GetDescendants()) do
                    if descendant:IsA("BasePart") and descendant.Transparency == 0.5 then
                        pcall(function() descendant.Transparency = 0 end)
                    end
                end
            end

            S.isInvisible = false
            if S.invisCharAddedConn then
                S.invisCharAddedConn:Disconnect()
                S.invisCharAddedConn = nil
            end

            S.sendNotif("Invisible: OFF")
        end
    end
end

--// ============================================================
--// FLY
--// ============================================================
do
    function S.startFly()
        if S.isFlying then return end
        local hrp = S.getHRP()
        if not hrp then return end
        S.isFlying = true
        local success = false
        pcall(function()
            S.flyBodyVelocity = Instance.new("BodyVelocity")
            S.flyBodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
            S.flyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
            S.flyBodyVelocity.P = 10000
            S.flyBodyVelocity.Parent = hrp
            S.flyBodyGyro = Instance.new("BodyGyro")
            S.flyBodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
            S.flyBodyGyro.P = 15000
            S.flyBodyGyro.D = 1000
            S.flyBodyGyro.Parent = hrp
            success = true
        end)
        if not success then S.flyBodyVelocity = nil; S.flyBodyGyro = nil end
        local camera = S.Workspace.CurrentCamera
        S.flyConn = S.RunService.Heartbeat:Connect(function(dt)
            if not S.isFlying then return end
            local char = S.getCharacter()
            if not char then return end
            local hr = char:FindFirstChild("HumanoidRootPart")
            if not hr then return end
            local camCF = camera.CFrame
            local direction = Vector3.new(0, 0, 0)
            if S.UserInputService:IsKeyDown(Enum.KeyCode.W) then direction = direction + camCF.LookVector end
            if S.UserInputService:IsKeyDown(Enum.KeyCode.S) then direction = direction - camCF.LookVector end
            if S.UserInputService:IsKeyDown(Enum.KeyCode.A) then direction = direction - camCF.RightVector end
            if S.UserInputService:IsKeyDown(Enum.KeyCode.D) then direction = direction + camCF.RightVector end
            if S.UserInputService:IsKeyDown(Enum.KeyCode.Space) then direction = direction + Vector3.new(0, 1, 0) end
            if S.UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then direction = direction - Vector3.new(0, 1, 0) end
            if direction.Magnitude > 0 then direction = direction.Unit * S.flySpeed end
            if S.flyBodyVelocity and S.flyBodyVelocity.Parent then
                S.flyBodyVelocity.Velocity = direction
                if S.flyBodyGyro and S.flyBodyGyro.Parent then S.flyBodyGyro.CFrame = camCF end
            else
                hr.CFrame = hr.CFrame + (direction * dt)
            end
        end)
    end

    function S.stopFly()
        S.isFlying = false
        if S.flyConn then S.flyConn:Disconnect(); S.flyConn = nil end
        if S.flyBodyVelocity then S.flyBodyVelocity:Destroy(); S.flyBodyVelocity = nil end
        if S.flyBodyGyro then S.flyBodyGyro:Destroy(); S.flyBodyGyro = nil end
    end

    function S.toggleFly()
        if S.isFlying then S.stopFly() else S.startFly() end
    end
end

--// ============================================================
--// MINING + SELL
--// ============================================================
do
    function S.findPickaxe()
        local char = S.getCharacter()
        if char then
            for _, item in ipairs(char:GetChildren()) do
                if item:IsA("Tool") or item.Name:lower():find("pick") then return item end
            end
        end
        local backpack = S.LocalPlayer:FindFirstChild("Backpack")
        if backpack then
            for _, item in ipairs(backpack:GetChildren()) do
                if item:IsA("Tool") or item.Name:lower():find("pick") then return item end
            end
        end
        return nil
    end

    function S.equipPickaxe()
        local char = S.getCharacter()
        if not char then return nil end
        local hum = char:FindFirstChildOfClass("Humanoid")
        -- Already equipped?
        for _, item in ipairs(char:GetChildren()) do
            if item:IsA("Tool") or item.Name:lower():find("pick") then return item end
        end
        -- In backpack? Equip
        local backpack = S.LocalPlayer:FindFirstChild("Backpack")
        if backpack then
            for _, item in ipairs(backpack:GetChildren()) do
                if item:IsA("Tool") or item.Name:lower():find("pick") then
                    if hum then pcall(function() hum:EquipTool(item) end) task.wait(0.3)
                    else pcall(function() item.Parent = char end) task.wait(0.3) end
                    return item
                end
            end
        end
        return nil
    end

    function S.mineRock(rock)
        local toolEvent = S.getToolEvent()
        if not toolEvent then return false end
        local pickaxe = S.findPickaxe()
        pcall(function()
            if pickaxe then
                toolEvent:FireServer("MineOres", pickaxe, rock)
                toolEvent:FireServer("MineOres", pickaxe, rock)
            else
                toolEvent:FireServer("MineOres", rock)
                toolEvent:FireServer("MineOres", rock)
            end
        end)
        return true
    end

    function S.sellOre()
        local sellRemote = S.getSellRemote()
        if not sellRemote then return false end
        local inventory = S.countInventoryItems()
        local soldSomething = false
        for oreName, count in pairs(inventory) do
            if count > 0 and S.ORE_PRICES[oreName] then
                pcall(function() sellRemote:FireServer(oreName, count) end)
                soldSomething = true
                task.wait(0.15)
            end
        end
        return soldSomething
    end

    function S.teleportTo(position)
        local hrp = S.getHRP()
        if hrp then hrp.CFrame = CFrame.new(position) end
    end

    function S.freezeCharacter()
        local hrp = S.getHRP()
        if not hrp then return end
        hrp.Anchored = true
        local char = S.getCharacter()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then part.Anchored = true end
            end
        end
    end

    function S.unfreezeCharacter()
        local hrp = S.getHRP()
        if hrp then hrp.Anchored = false end
        local char = S.getCharacter()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then part.Anchored = false end
            end
        end
    end

    function S.interactWithNPC(npc)
        for _, desc in ipairs(npc:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then fireproximityprompt(desc) task.wait(0.5) return true end
        end
        for _, desc in ipairs(npc:GetDescendants()) do
            if desc:IsA("ClickDetector") then fireclickdetector(desc) task.wait(0.5) return true end
        end
        return false
    end

    function S.sellAllOre()
        S.unfreezeCharacter()
        S.removePlatform()
        task.wait(0.1)
        local buyer = S.getMineralBuyer()
        if not buyer then S.teleportTo(S.CAVE_POS) task.wait(0.5) return end
        local buyerPos = buyer:FindFirstChild("HumanoidRootPart") and buyer.HumanoidRootPart.Position
            or buyer.PrimaryPart and buyer.PrimaryPart.Position
            or (buyer:IsA("BasePart") and buyer.Position)
        if buyerPos then S.teleportTo(buyerPos + Vector3.new(0, 0, 3)) task.wait(0.5) end
        S.interactWithNPC(buyer)
        task.wait(0.3)
        S.sellOre()
        task.wait(0.5)
        local invAfter = S.countInventoryItems()
        local oreAfter = S.getTotalOreCount(invAfter)
        if oreAfter > 0 then S.sellOre() task.wait(0.5) end
        S.teleportTo(S.CAVE_POS)
        task.wait(0.5)
    end
end

--// ============================================================
--// MAIN FARM LOOP (SIDE only, with platform)
--// ============================================================
do
    function S.farmLoop()
        while S.isFarming do
            local rock = S.findNearestRock(S.minedRocks)
            if not rock then S.minedRocks = {} task.wait(2) continue end
            if not S.isRockValid(rock) then table.insert(S.minedRocks, rock) continue end
            local hrp = S.getHRP()
            if not hrp then task.wait(1) continue end
            local distToCave = (hrp.Position - S.CAVE_POS).Magnitude
            if distToCave > 200 then S.teleportTo(S.CAVE_POS) task.wait(0.5) end

            local rockPos = rock.Position
            local direction = (hrp.Position - rockPos).Unit
            local standPos = rockPos + (direction * S.MINING_DISTANCE)
            standPos = Vector3.new(standPos.X, rockPos.Y + 3, standPos.Z)

            S.teleportTo(standPos)
            S.createPlatform(standPos)
            task.wait(0.1)
            S.freezeCharacter()
            local myHrp = S.getHRP()
            if myHrp then myHrp.CFrame = CFrame.new(standPos, rockPos) S.freezeCharacter() end

            -- Equip pickaxe once for this rock
            S.equipPickaxe()
            task.wait(0.2)

            local hitCount = 0
            local maxHits = 60
            local noProgressHits = 0
            local lastHP = rock:GetAttribute("HP") or rock:GetAttribute("Health")
            while S.isFarming and hitCount < maxHits do
                if rock.Parent == nil or not S.Workspace:IsAncestorOf(rock) then break end
                if rock:GetAttribute("Destroyed") == true then break end
                if not S.isRockValid(rock) then break end
                local myHrp2 = S.getHRP()
                if myHrp2 then
                    if not myHrp2.Anchored then myHrp2.Anchored = true end
                    if (myHrp2.Position - standPos).Magnitude > 1 then
                        myHrp2.CFrame = CFrame.new(standPos, rockPos)
                        S.freezeCharacter()
                    end
                end
                S.mineRock(rock)
                hitCount = hitCount + 1
                task.wait(S.HIT_INTERVAL)
                local currentHP = rock:GetAttribute("HP") or rock:GetAttribute("Health")
                if currentHP and lastHP and currentHP < lastHP then
                    noProgressHits = 0
                    lastHP = currentHP
                else
                    noProgressHits = noProgressHits + 1
                end
                local invNow = S.countInventoryItems()
                local oreNow = S.getTotalOreCount(invNow)
                if oreNow > S.totalOreMined then
                    local gained = oreNow - S.totalOreMined
                    S.totalOreMined = S.totalOreMined + gained
                    S.currentSessionOre = S.currentSessionOre + gained
                end
                if noProgressHits >= 15 then break end
            end
            table.insert(S.minedRocks, rock)
            S.lastRockPosition = rock.Position
            S.unfreezeCharacter()
            S.removePlatform()
            local currentInv = S.countInventoryItems()
            local totalOre = S.getTotalOreCount(currentInv)
            if totalOre >= S.SELL_THRESHOLD then
                local earnings = S.calculateEarnings(currentInv)
                S.totalEarnings = S.totalEarnings + earnings
                S.currentSessionEarnings = S.currentSessionEarnings + earnings
                S.sellAllOre()
            end
            task.wait(0.1)
        end
        S.unfreezeCharacter()
        S.removePlatform()
    end

    function S.startFarming()
        if S.isFarming then return end
        S.isFarming = true
        S.farmStartTime = tick()
        S.frozenTimeStr = "00:00:00"
        S.frozenOreCount = 0
        S.frozenEarnings = 0
        S.currentSessionOre = 0
        S.currentSessionEarnings = 0
        S.minedRocks = {}
        S.toggleNoFallDMG(true)
        S.teleportTo(S.CAVE_POS)
        task.wait(0.5)
        S.equipPickaxe()
        task.wait(0.3)
        S.farmThread = coroutine.wrap(S.farmLoop)
        S.farmThread()
    end

    function S.stopFarming()
        S.isFarming = false
        S.unfreezeCharacter()
        S.removePlatform()
        if S.farmStartTime > 0 then S.frozenTimeStr = S.formatTime(tick() - S.farmStartTime) end
        S.frozenOreCount = S.currentSessionOre
        S.frozenEarnings = S.currentSessionEarnings
    end
end

--// ============================================================
--// ARM WRESTLING
--// ============================================================
do
    local ArmWrestlingEvent = S.ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("ArmWrestlingEvent")

    function S.awStartNormalSpam()
        if S.awSpamThread then return end
        S.awSpamThread = task.spawn(function()
            while S.awMatchActive and S.awCurrentRemote and S.awAutoEnabled do
                pcall(function()
                    if S.awCurrentRemote then
                        S.awCurrentRemote:FireServer(1)
                        S.awTotalFires = S.awTotalFires + 1
                    end
                end)
                task.wait(S.awNormalDelay)
            end
            S.awSpamThread = nil
        end)
    end

    function S.awStopNormalSpam() S.awSpamThread = nil end

    function S.awStartSuperFast()
        if S.awSuperFastConn then return end
        S.awSuperFastConn = S.RunService.Heartbeat:Connect(function()
            if not S.awMatchActive or not S.awCurrentRemote then return end
            pcall(function()
                for i = 1, S.awSuperFiresPF do S.awCurrentRemote:FireServer(1) end
            end)
            S.awTotalFires = S.awTotalFires + S.awSuperFiresPF
        end)
    end

    function S.awStopSuperFast()
        if S.awSuperFastConn then S.awSuperFastConn:Disconnect(); S.awSuperFastConn = nil end
    end

    function S.awStopAll() S.awStopNormalSpam() S.awStopSuperFast() end

    ArmWrestlingEvent.OnClientEvent:Connect(function(action, ...)
        if action == "BeginMatch" then
            S.awCurrentRemote = ...
            S.awMatchActive = true
            if S.awAutoEnabled then
                if S.awSuperFastMode then S.awStartSuperFast() else S.awStartNormalSpam() end
            end
        elseif action == "MatchComplete" then
            S.awMatchActive = false
            S.awStopAll()
            S.awCurrentRemote = nil
        end
    end)
end

--// ============================================================
--// PULL-UP BAR AUTO (OSU-like clicker game) — v0.11 REWRITE
--// ============================================================
-- Flow:
--   1. User climbs on the bar manually (script NEVER auto-climbs)
--   2. Script detects game start via OnClientEvent OR Gema.Visible
--   3. Script auto-clicks buttons with perfect timing via RenderStepped
--   4. Deep search for BorderOffset, ALL click methods (firesignal,
--      MouseButton1Down/Up, getconnections, VirtualUser ClickButton1)
--   5. Game ends when Gema.Visible becomes false
--//=============================================================
do
    local PullUpEvent = S.ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("PullUpEvent")

    -- Get the game GUI canvas where buttons spawn
    local function getGameCanvas()
        local pg = S.LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then return nil end
        local sg = pg:FindFirstChild("StaticGui")
        if not sg then return nil end
        local ag = sg:FindFirstChild("AimGame")
        if not ag then return nil end
        local gema = ag:FindFirstChild("Gema")
        if not gema then return nil end
        return gema:FindFirstChild("Canvas")
    end

    -- Get the game score value
    local function getGameScoreValue()
        local pg = S.LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then return nil end
        local sg = pg:FindFirstChild("StaticGui")
        if not sg then return nil end
        local ag = sg:FindFirstChild("AimGame")
        if not ag then return nil end
        local sv = ag:FindFirstChild("ScoreValue")
        if sv and (sv:IsA("IntValue") or sv:IsA("NumberValue")) then return sv end
        return nil
    end

    -- Check if the OSU game GUI is visible
    local function isGameActive()
        local pg = S.LocalPlayer:FindFirstChild("PlayerGui")
        if not pg then return false end
        local sg = pg:FindFirstChild("StaticGui")
        if not sg then return false end
        local ag = sg:FindFirstChild("AimGame")
        if not ag then return false end
        local gema = ag:FindFirstChild("Gema")
        if not gema then return false end
        return gema.Visible
    end

    -- Deep search for BorderOffset value ANYWHERE in the button hierarchy
    -- Searches up to 6 levels deep, finds any NumberValue/IntValue named BorderOffset
    local function findBorderOffset(parent, depth)
        depth = depth or 0
        if depth > 6 then return nil end
        for _, child in ipairs(parent:GetChildren()) do
            if child.Name == "BorderOffset" and (child:IsA("NumberValue") or child:IsA("IntValue")) then
                return child.Value
            end
            local result = findBorderOffset(child, depth + 1)
            if result then return result end
        end
        return nil
    end

    -- Find ALL TextButtons/ImageButtons recursively (any depth)
    local function findAllButtons(parent, result)
        result = result or {}
        for _, child in ipairs(parent:GetChildren()) do
            if child:IsA("TextButton") or child:IsA("ImageButton") then
                table.insert(result, child)
            end
            findAllButtons(child, result)
        end
        return result
    end

    -- Click a GUI button using ALL possible methods for maximum compatibility
    local function clickButton(btn)
        -- Method 1: firesignal MouseButton1Click
        pcall(function() firesignal(btn.MouseButton1Click) end)
        -- Method 2: firesignal MouseButton1Down + Up (some games use these)
        pcall(function() firesignal(btn.MouseButton1Down) end)
        pcall(function() firesignal(btn.MouseButton1Up) end)
        -- Method 3: getconnections — directly fire all connected functions
        pcall(function()
            for _, conn in ipairs(getconnections(btn.MouseButton1Click)) do
                conn:Fire()
            end
        end)
        pcall(function()
            for _, conn in ipairs(getconnections(btn.MouseButton1Down)) do
                conn:Fire()
            end
        end)
        -- Method 4: VirtualUser ClickButton1 (LEFT CLICK — not ClickButton2!)
        pcall(function()
            local pos = btn.AbsolutePosition
            local size = btn.AbsoluteSize
            if pos and size and pos.X > 0 and pos.Y > 0 then
                S.VirtualUser:CaptureController()
                S.VirtualUser:ClickButton1(Vector2.new(
                    pos.X + size.X / 2,
                    pos.Y + size.Y / 2
                ))
            end
        end)
    end



    -- Start the auto-clicker using task.wait delay approach:
    -- When a NEW circle appears on canvas → wait pullUpClickDelay seconds → click it.
    -- Much simpler and more reliable than BorderOffset reading.
    local function startAutoClicker()
        if S.pullUpClickConn then S.pullUpClickConn:Disconnect() end
        S.pullUpClickedSet = {}

        S.pullUpClickConn = S.RunService.RenderStepped:Connect(function()
            if not S.isPullUpActive or not S.pullUpOnBar then
                if S.pullUpClickConn then
                    S.pullUpClickConn:Disconnect()
                    S.pullUpClickConn = nil
                end
                return
            end

            -- Check if game ended
            if not isGameActive() then
                S.pullUpOnBar = false
                if S.pullUpClickConn then
                    S.pullUpClickConn:Disconnect()
                    S.pullUpClickConn = nil
                end
                return
            end

            local canvas = getGameCanvas()
            if not canvas then return end

            -- Find NEW circles (visible GuiObjects we haven't scheduled yet)
            for _, child in ipairs(canvas:GetChildren()) do
                if child:IsA("GuiObject") and child.Name ~= "Quit" and child.Visible
                    and not S.pullUpClickedSet[child] then

                    -- Mark as scheduled immediately so we don't double-schedule
                    S.pullUpClickedSet[child] = true

                    -- Schedule click after delay in a new thread
                    local capturedChild = child
                    task.spawn(function()
                        task.wait(S.pullUpClickDelay)

                        -- Double-check it's still visible before clicking
                        if not capturedChild or not capturedChild.Parent or not capturedChild.Visible then
                            return
                        end

                        -- Find buttons inside this circle and click them
                        local btns = findAllButtons(capturedChild)
                        if #btns > 0 then
                            for _, btn in ipairs(btns) do
                                clickButton(btn)
                            end
                        else
                            -- No inner buttons, try clicking the frame itself
                            clickButton(capturedChild)
                            for _, desc in ipairs(capturedChild:GetDescendants()) do
                                if desc:IsA("TextButton") or desc:IsA("ImageButton") then
                                    clickButton(desc)
                                end
                            end
                        end
                    end)
                end
            end
        end)
    end

    -- Find the pull-up bar object in workspace (broad search)
    local function findPullUpBar()
        -- Search strategy: look for objects with names containing pull/bar/chinup
        -- in Tasks > Prisoner, then broader search in Workspace
        local searchNames = {"pull", "bar", "chinup", "chin_up", "hang"}
        local function nameMatch(name)
            local lower = name:lower()
            for _, kw in ipairs(searchNames) do
                if lower:find(kw) then return true end
            end
            return false
        end

        -- Search 1: Tasks > Prisoner (most likely location)
        local tasks = S.Workspace:FindFirstChild("Tasks")
        if tasks then
            local prisoner = tasks:FindFirstChild("Prisoner")
            if prisoner then
                for _, obj in ipairs(prisoner:GetChildren()) do
                    if nameMatch(obj.Name) then return obj end
                end
            end
            -- Search entire Tasks folder
            for _, obj in ipairs(tasks:GetDescendants()) do
                if nameMatch(obj.Name) and (obj:IsA("Model") or obj:IsA("BasePart")) then return obj end
            end
        end

        -- Search 2: Workspace top-level
        for _, obj in ipairs(S.Workspace:GetChildren()) do
            if nameMatch(obj.Name) and (obj:IsA("Model") or obj:IsA("BasePart")) then return obj end
        end

        -- Search 3: Look for objects with ProximityPrompt that are near the player
        -- and might be pull-up bars
        local hrp = S.getHRP()
        if hrp then
            local bestPrompt = nil
            local bestDist = math.huge
            if tasks then
                for _, desc in ipairs(tasks:GetDescendants()) do
                    if desc:IsA("ProximityPrompt") then
                        local part = desc.Parent
                        if part then
                            local pos = nil
                            if part:IsA("BasePart") then
                                pos = part.Position
                            elseif part:IsA("Model") and part.PrimaryPart then
                                pos = part.PrimaryPart.Position
                            end
                            if pos then
                                local dist = (pos - hrp.Position).Magnitude
                                if dist < bestDist and dist < 100 then
                                    bestDist = dist
                                    bestPrompt = desc
                                end
                            end
                        end
                    end
                end
            end
            if bestPrompt then
                return bestPrompt.Parent
            end
        end

        return nil
    end

    -- Get position of a bar object (Model or BasePart)
    local function getBarPosition(barObj)
        if not barObj then return nil end
        if barObj:IsA("BasePart") then return barObj.Position end
        if barObj:IsA("Model") then
            if barObj.PrimaryPart then return barObj.PrimaryPart.Position end
            -- Try finding first BasePart
            for _, desc in ipairs(barObj:GetDescendants()) do
                if desc:IsA("BasePart") then return desc.Position end
            end
        end
        return nil
    end

    -- Find the specific Part/Instance that has the ProximityPrompt or ClickDetector
    local function findInteractablePart(barObj)
        if not barObj then return nil end
        -- Check barObj itself
        for _, desc in ipairs(barObj:GetDescendants()) do
            if desc:IsA("ProximityPrompt") then return desc end
            if desc:IsA("ClickDetector") then return desc end
        end
        return nil
    end

    -- Climb the pull-up bar: PRIMARY METHOD = Interact remote
    -- Teleport to bar first, then fire Interact.Event:FireServer(barObj)
    local function climbPullUpBar()
        -- Step 1: Find the bar object
        local barObj = findPullUpBar()

        -- Step 2: Teleport near the bar if found
        if barObj then
            local barPos = getBarPosition(barObj)
            if barPos then
                local hrp = S.getHRP()
                if hrp and (hrp.Position - barPos).Magnitude > 5 then
                    S.teleportTo(barPos + Vector3.new(0, 0, 3))
                    task.wait(0.5)
                end
            end
        end

        -- Step 3: PRIMARY — Fire Interact.Event:FireServer(barObj)
        local interactOk = false
        pcall(function()
            local remotes = S.ReplicatedStorage:FindFirstChild("Remotes")
            if remotes then
                local interact = remotes:FindFirstChild("Interact")
                if interact then
                    local event = interact:FindFirstChild("Event")
                    if event and event:IsA("RemoteEvent") then
                        if barObj then
                            event:FireServer(barObj)
                        else
                            event:FireServer()
                        end
                        interactOk = true
                    end
                end
            end
        end)
        if interactOk then task.wait(0.3) end

        -- Step 4: BACKUP — fireproximityprompt if Interact didn't work
        pcall(function()
            if barObj then
                for _, desc in ipairs(barObj:GetDescendants()) do
                    if desc:IsA("ProximityPrompt") then
                        fireproximityprompt(desc)
                        return
                    end
                end
                for _, desc in ipairs(barObj:GetDescendants()) do
                    if desc:IsA("ClickDetector") then
                        fireclickdetector(desc)
                        return
                    end
                end
            end
        end)
    end

    function S.startPullUp()
        if S.isPullUpActive then return end
        S.isPullUpActive = true
        S.pullUpCycles = 0
        S.pullUpScore = 0
        S.pullUpOnBar = false

        S.sendNotif("Pull-Up Auto ON - climb the bar!")

        -- Listen for game start from server (fires when user climbs on)
        S._pullUpListener = PullUpEvent.OnClientEvent:Connect(function(...)
            if not S.isPullUpActive then return end
            if not S.pullUpOnBar then
                S.pullUpOnBar = true
                S.pullUpGameDuration = 60
                S.pullUpCycles = S.pullUpCycles + 1
                S.sendNotif("Pull-Up Game started!")
                task.delay(0.3, function()
                    if S.isPullUpActive and S.pullUpOnBar then
                        startAutoClicker()
                    end
                end)
            end
        end)

        -- If game is already active (user already climbed before enabling), detect it
        if isGameActive() then
            S.pullUpOnBar = true
            S.pullUpCycles = S.pullUpCycles + 1
            S.sendNotif("Pull-Up: game already active!")
            startAutoClicker()
        end

        -- Monitor thread: poll for game start, update score, detect game end,
        -- and AUTO CLIMB back if enabled and character got off
        S.pullUpMonitorThread = task.spawn(function()
            while S.isPullUpActive do
                -- If not on bar yet, check if game GUI appeared (missed OnClientEvent)
                if not S.pullUpOnBar and isGameActive() then
                    S.pullUpOnBar = true
                    S.pullUpCycles = S.pullUpCycles + 1
                    S.sendNotif("Pull-Up: detected active game!")
                    startAutoClicker()
                end

                if S.pullUpOnBar then
                    local sv = getGameScoreValue()
                    if sv then S.pullUpScore = sv.Value end
                    -- Check if game ended (character got off the bar)
                    if not isGameActive() then
                        S.pullUpOnBar = false
                        if S.pullUpClickConn then
                            S.pullUpClickConn:Disconnect()
                            S.pullUpClickConn = nil
                        end
                        -- AUTO CLIMB: if enabled, try to climb back on with retries
                        if S.pullUpAutoClimb then
                            S.sendNotif("Pull-Up: auto-climbing back...")
                            task.delay(1.5, function()
                                if not S.isPullUpActive then return end
                                -- Try climbing up to 3 times
                                for attempt = 1, 3 do
                                    if not S.isPullUpActive then return end
                                    if S.pullUpOnBar then return end
                                    climbPullUpBar()
                                    task.wait(1.5)
                                    -- Check if it worked (game GUI appeared)
                                    if isGameActive() then
                                        S.pullUpOnBar = true
                                        S.pullUpCycles = S.pullUpCycles + 1
                                        startAutoClicker()
                                        return
                                    end
                                end
                            end)
                        end
                    end
                end
                task.wait(0.3)
            end
            if S._pullUpListener then
                S._pullUpListener:Disconnect()
                S._pullUpListener = nil
            end
        end)
    end

    function S.stopPullUp()
        S.isPullUpActive = false
        S.pullUpOnBar = false
        S.pullUpAutoClimb = false
        S.pullUpClickedSet = {}
        if S._pullUpListener then
            S._pullUpListener:Disconnect()
            S._pullUpListener = nil
        end
        if S.pullUpClickConn then
            S.pullUpClickConn:Disconnect()
            S.pullUpClickConn = nil
        end
    end
end

--// ============================================================
--// STAFF DETECTION (NewPlayerGroupDetails)
--// ============================================================
do
    local DANGEROUS_ROLES = { Admin = true, PlaceCreator = true, Intern = true, Star = true }

    local function getPlayerNameById(userId)
        local ok, name = pcall(function() return S.Players:GetNameFromUserIdAsync(tonumber(userId)) end)
        return ok and name or tostring(userId)
    end

    -- ALERT SOUND: User's verified sound. Plays 3 times.
    -- Uses S._isAlertPlaying so the hookmetamethod can block other sounds during alert.
    local function playAlertSound()
        if S._isAlertPlaying then return end
        S._isAlertPlaying = true

        -- Immediately stop any currently playing sounds that aren't ours
        local ALERT_ID = "rbxassetid://132238052138705"
        pcall(function()
            for _, svc in ipairs({S.Workspace.CurrentCamera, game:GetService("SoundService")}) do
                for _, s in ipairs(svc:GetChildren()) do
                    if s:IsA("Sound") and s.IsPlaying and s.SoundId ~= ALERT_ID then
                        s:Stop()
                    end
                end
            end
        end)
        pcall(function()
            local pg = S.LocalPlayer:FindFirstChild("PlayerGui")
            if pg then
                for _, desc in ipairs(pg:GetDescendants()) do
                    if desc:IsA("Sound") and desc.IsPlaying and desc.SoundId ~= ALERT_ID then
                        desc:Stop()
                    end
                end
            end
        end)

        task.spawn(function()
            pcall(function()
                for i = 1, 3 do
                    local sound = Instance.new("Sound")
                    sound.SoundId = ALERT_ID
                    sound.Volume = 3
                    sound.Looped = false
                    sound.Parent = S.Workspace.CurrentCamera
                    if not sound.IsLoaded then
                        sound.Loaded:Wait()
                    end
                    sound:Play()
                    sound.Ended:Wait()
                    sound:Destroy()
                    if i < 3 then task.wait(0.3) end
                end
            end)

            S._isAlertPlaying = false
        end)
    end

    local function onStaffDetected(userId, roles)
        playAlertSound()
    end

    pcall(function()
        local RobloxReplicatedStorage = game:GetService("RobloxReplicatedStorage")
        -- Use FindFirstChild instead of WaitForChild to prevent blocking/crash
        local remote = RobloxReplicatedStorage:FindFirstChild("NewPlayerGroupDetails")
        if remote and remote:IsA("RemoteEvent") then
            remote.OnClientEvent:Connect(function(data)
                if type(data) ~= "table" then return end
                for userId, groups in pairs(data) do
                    if type(groups) == "table" then
                        local detected = {}
                        for role, val in pairs(groups) do
                            if val == true and DANGEROUS_ROLES[role] then table.insert(detected, role) end
                        end
                        if #detected > 0 then onStaffDetected(userId, detected) end
                    end
                end
            end)
        end
    end)
end

--// ============================================================
--// TRASH COLLECTION (Auto-pickup + deposit loop)
--// ============================================================
-- Trash objects: workspace.Tasks.Prisoner.Trashes (MeshParts named Big/Medium/Small)
-- Pickup remote: trashObj.Prompt.Interact.Event:FireServer()
-- Deposit remote: workspace.Map.Cells.Basement["Recyclement Room"].Props["Opened Trash"].Trash.Prompt.Interact.Event:FireServer()
-- No need to hold trash — just fire remotes
--//=============================================================
do
    local function getTrashesParent()
        local tasks = S.Workspace:FindFirstChild("Tasks")
        if not tasks then return nil end
        local prisoner = tasks:FindFirstChild("Prisoner")
        if not prisoner then return nil end
        return prisoner:FindFirstChild("Trashes")
    end

    -- Get deposit remote
    local function getDepositRemote()
        local map = S.Workspace:FindFirstChild("Map")
        if not map then return nil end
        local cells = map:FindFirstChild("Cells")
        if not cells then return nil end
        local basement = cells:FindFirstChild("Basement")
        if not basement then return nil end
        local recyclement = basement:FindFirstChild("Recyclement Room")
        if not recyclement then return nil end
        local props = recyclement:FindFirstChild("Props")
        if not props then return nil end
        local openedTrash = props:FindFirstChild("Opened Trash")
        if not openedTrash then return nil end
        local trash = openedTrash:FindFirstChild("Trash")
        if not trash then return nil end
        local prompt = trash:FindFirstChild("Prompt")
        if not prompt then return nil end
        local interact = prompt:FindFirstChild("Interact")
        if not interact then return nil end
        return interact:FindFirstChild("Event")
    end

    -- Find all available trash MeshParts directly in Trashes folder
    local function findAllTrash()
        local trashes = getTrashesParent()
        if not trashes then return {} end
        local result = {}
        for _, trashObj in ipairs(trashes:GetChildren()) do
            if trashObj:IsA("BasePart") or trashObj:IsA("Model") then
                -- Check if it has the Interact remote (means it's collectible)
                local hasRemote = false
                pcall(function()
                    hasRemote = trashObj:FindFirstChild("Prompt")
                        and trashObj.Prompt:FindFirstChild("Interact")
                        and trashObj.Prompt.Interact:FindFirstChild("Event")
                end)
                -- Check if visible/not collected
                local visible = true
                if trashObj:IsA("BasePart") then
                    visible = trashObj.Transparency < 1
                end
                if visible or hasRemote then
                    table.insert(result, trashObj)
                end
            end
        end
        return result
    end

    -- Fire the pickup remote for a trash object
    local function pickupTrash(trashObj)
        return pcall(function()
            local event = trashObj:FindFirstChild("Prompt")
                and trashObj.Prompt:FindFirstChild("Interact")
                and trashObj.Prompt.Interact:FindFirstChild("Event")
            if event then
                event:FireServer()
            end
        end)
    end

    -- Fire the deposit remote at the Recyclement Room bin
    local function depositTrash()
        return pcall(function()
            local remote = getDepositRemote()
            if remote then
                remote:FireServer()
            end
        end)
    end

    -- Get player's current money
    local function getPlayerMoney()
        local money = 0
        pcall(function()
            for _, desc in ipairs(S.LocalPlayer:GetDescendants()) do
                if (desc:IsA("NumberValue") or desc:IsA("IntValue")) and desc.Name:lower():find("money") then
                    money = desc.Value
                    break
                end
            end
        end)
        -- Also try leaderstats
        pcall(function()
            local ls = S.LocalPlayer:FindFirstChild("leaderstats")
            if ls then
                for _, v in ipairs(ls:GetChildren()) do
                    if v.Name:lower():find("money") or v.Name:lower():find("cash") or v.Name == "Money" then
                        money = v.Value
                        break
                    end
                end
            end
        end)
        return money
    end

    function S.startTrashFarm()
        if S.isTrashFarming then return end
        S.isTrashFarming = true
        S.trashCollected = 0
        S.trashTotal = 0
        S.trashEarnings = 0
        S.trashSessionStartMoney = getPlayerMoney()

        -- Save return position (where player is now)
        local hrp = S.getHRP()
        if hrp then
            S.trashReturnPos = hrp.Position
        end

        S.trashFarmThread = task.spawn(function()
            while S.isTrashFarming do
                local trashList = findAllTrash()
                S.trashTotal = #trashList

                if #trashList == 0 then
                    -- No trash left, wait for respawn
                    S.sendNotif("All trash collected! Waiting 15s for respawn...")
                    task.wait(15)
                    -- Re-check
                    trashList = findAllTrash()
                    S.trashTotal = #trashList
                    if #trashList == 0 then
                        -- Still nothing, try one more time
                        task.wait(15)
                        trashList = findAllTrash()
                        S.trashTotal = #trashList
                        if #trashList == 0 then
                            -- Calculate earnings
                            S.trashEarnings = getPlayerMoney() - S.trashSessionStartMoney
                            -- Return to start
                            if S.trashReturnPos then
                                S.teleportTo(S.trashReturnPos)
                            end
                            S.sendNotif("No more trash! Earned: $" .. S.trashEarnings)
                            S.isTrashFarming = false
                            break
                        end
                    end
                end

                -- Process each trash object
                for _, trashObj in ipairs(trashList) do
                    if not S.isTrashFarming then break end

                    -- 1. Teleport to trash
                    local trashPos = nil
                    if trashObj:IsA("BasePart") then trashPos = trashObj.Position end
                    if not trashPos and trashObj:IsA("Model") and trashObj.PrimaryPart then
                        trashPos = trashObj.PrimaryPart.Position
                    end
                    if not trashPos then continue end

                    S.teleportTo(trashPos + Vector3.new(0, 3, 0))
                    task.wait(0.4)

                    -- 2. Pick up trash (fire remote, no need to hold)
                    pickupTrash(trashObj)
                    task.wait(0.4)

                    -- 3. Teleport to bin and deposit
                    if S.trashBinPos then
                        S.teleportTo(S.trashBinPos + Vector3.new(0, 3, 0))
                        task.wait(0.4)
                        depositTrash()
                        task.wait(0.5)
                        S.trashCollected = S.trashCollected + 1
                    else
                        S.sendNotif("No bin position set! Stand at bin and press SET BIN POS.")
                        S.isTrashFarming = false
                        break
                    end
                end

                -- Update earnings
                S.trashEarnings = getPlayerMoney() - S.trashSessionStartMoney

                -- Brief pause before next cycle
                task.wait(1)
            end

            -- Final earnings calculation
            S.trashEarnings = getPlayerMoney() - S.trashSessionStartMoney
            -- Return to start position
            if S.trashReturnPos and not S.isTrashFarming then
                S.teleportTo(S.trashReturnPos)
            end
            S.trashFarmThread = nil
        end)
    end

    function S.stopTrashFarm()
        S.isTrashFarming = false
        S.trashEarnings = getPlayerMoney() - S.trashSessionStartMoney
    end
end

--// ============================================================
--// SPAM HEAD/BLINK (UnreliableReplicationEvent)
--// ============================================================
-- Spam head rotation + eye blink to potentially lag other players
--//=============================================================
do
    local ReplicationEvent = S.ReplicatedStorage:WaitForChild("Remotes"):WaitForChild("UnreliableReplicationEvent")

    function S.toggleSpamHead(enable)
        if enable then
            S.isSpammingHead = true
            if S.spamHeadConn then S.spamHeadConn:Disconnect() end

            S.spamHeadConn = S.RunService.Heartbeat:Connect(function()
                if not S.isSpammingHead then return end
                pcall(function()
                    local char = S.getCharacter()
                    if not char then return end
                    local head = char:FindFirstChild("Head")
                    local torso = char:FindFirstChild("Torso")
                    if not head or not torso then return end

                    local neck = torso:FindFirstChild("Neck")
                    if not neck then return end

                    -- Random neck CFrame (wild head movement)
                    local rx = math.random() * 2 - 1
                    local ry = math.random() * 2 - 1
                    local rz = math.random() * 2 - 1
                    local randomCF = CFrame.new(0, 0.9, 0) * CFrame.Angles(rx * math.pi, ry * math.pi, rz * math.pi)

                    -- Spam MoveNeck
                    pcall(function()
                        ReplicationEvent:FireServer("MoveNeck", {
                            Motor = neck,
                            NewCF = randomCF,
                        })
                    end)

                    -- Spam BlinkOnce (every other frame for max spam)
                    pcall(function()
                        ReplicationEvent:FireServer("BlinkOnce", {
                            Head = head,
                        })
                    end)
                end)
            end)
            S.sendNotif("Spam Head: ON")
        else
            S.isSpammingHead = false
            if S.spamHeadConn then
                S.spamHeadConn:Disconnect()
                S.spamHeadConn = nil
            end
            S.sendNotif("Spam Head: OFF")
        end
    end
end

--// ============================================================
--// UI — Red Minimal Theme (Mobile-Friendly)
--// ============================================================
do
    local ScreenGui = Instance.new("ScreenGui")
    ScreenGui.Name = "TopBarApp"
    ScreenGui.ResetOnSpawn = false
    ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    ScreenGui.Parent = game:GetService("CoreGui")

    local isMinimized = false

    -- Minimized button
    local MinBtn = Instance.new("TextButton")
    MinBtn.Name = "RB"
    MinBtn.Size = UDim2.new(0, 44, 0, 44)
    MinBtn.Position = UDim2.new(0, 10, 0.5, -22)
    MinBtn.BackgroundColor3 = Color3.fromRGB(50, 15, 15)
    MinBtn.BorderSizePixel = 0
    MinBtn.Text = "AI"
    MinBtn.TextColor3 = Color3.fromRGB(255, 120, 120)
    MinBtn.Font = Enum.Font.GothamBold
    MinBtn.TextSize = 14
    MinBtn.Visible = false
    MinBtn.Parent = ScreenGui
    Instance.new("UICorner", MinBtn).CornerRadius = UDim.new(0, 22)
    do local s = Instance.new("UIStroke") s.Color = Color3.fromRGB(120, 40, 40) s.Thickness = 1.5 s.Parent = MinBtn end

    -- Main Frame
    local MainFrame = Instance.new("Frame")
    MainFrame.Name = "Container"
    MainFrame.Size = UDim2.new(0, 230, 0, 380)
    MainFrame.Position = UDim2.new(0.02, 0, 0.5, -190)
    MainFrame.BackgroundColor3 = Color3.fromRGB(25, 12, 12)
    MainFrame.BorderSizePixel = 0
    MainFrame.Active = true
    -- Manual drag (replaces deprecated Draggable)
    local dragSpeed = 0.08
    local dragInput = nil
    local dragStart = nil
    local startPos = nil
    MainFrame.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragStart = input.Position
            startPos = MainFrame.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragStart = nil
                end
            end)
        end
    end)
    MainFrame.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)
    S.UserInputService.InputChanged:Connect(function(input)
        if input == dragInput and dragStart and startPos then
            local delta = input.Position - dragStart
            MainFrame.Position = UDim2.new(
                startPos.X.Scale, startPos.X.Offset + delta.X,
                startPos.Y.Scale, startPos.Y.Offset + delta.Y
            )
        end
    end)
    MainFrame.Parent = ScreenGui
    Instance.new("UICorner", MainFrame).CornerRadius = UDim.new(0, 8)
    do local s = Instance.new("UIStroke") s.Color = Color3.fromRGB(120, 40, 40) s.Thickness = 1.5 s.Parent = MainFrame end

    -- Title Bar
    local TitleBar = Instance.new("Frame")
    TitleBar.Size = UDim2.new(1, 0, 0, 30)
    TitleBar.BackgroundColor3 = Color3.fromRGB(45, 12, 12)
    TitleBar.BorderSizePixel = 0
    TitleBar.Parent = MainFrame
    Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0, 8)
    do
        local tl = Instance.new("TextLabel")
        tl.Text = "AI SCRIPT v0.17"
        tl.Size = UDim2.new(1, -55, 1, 0)
        tl.Position = UDim2.new(0, 8, 0, 0)
        tl.BackgroundTransparency = 1
        tl.TextColor3 = Color3.fromRGB(255, 120, 120)
        tl.Font = Enum.Font.GothamBold
        tl.TextSize = 12
        tl.TextXAlignment = Enum.TextXAlignment.Left
        tl.Parent = TitleBar
    end

    -- Hide / Close buttons
    do
        local hb = Instance.new("TextButton")
        hb.Name = "HB" hb.Text = "-" hb.Size = UDim2.new(0, 22, 0, 22) hb.Position = UDim2.new(1, -50, 0, 4)
        hb.BackgroundColor3 = Color3.fromRGB(60, 20, 20) hb.TextColor3 = Color3.fromRGB(255, 255, 255)
        hb.Font = Enum.Font.GothamBold hb.TextSize = 12 hb.BorderSizePixel = 0 hb.Parent = TitleBar
        Instance.new("UICorner", hb).CornerRadius = UDim.new(0, 4)
        S.Buttons.HideBtn = hb

        local cb = Instance.new("TextButton")
        cb.Name = "XB" cb.Text = "X" cb.Size = UDim2.new(0, 22, 0, 22) cb.Position = UDim2.new(1, -26, 0, 4)
        cb.BackgroundColor3 = Color3.fromRGB(180, 40, 40) cb.TextColor3 = Color3.fromRGB(255, 255, 255)
        cb.Font = Enum.Font.GothamBold cb.TextSize = 10 cb.BorderSizePixel = 0 cb.Parent = TitleBar
        Instance.new("UICorner", cb).CornerRadius = UDim.new(0, 4)
        S.Buttons.CloseBtn = cb
    end

    -- Content ScrollFrame
    local Content = Instance.new("ScrollingFrame")
    Content.Size = UDim2.new(1, -12, 1, -36)
    Content.Position = UDim2.new(0, 6, 0, 33)
    Content.BackgroundTransparency = 1
    Content.BorderSizePixel = 0
    Content.ScrollBarThickness = 3
    Content.ScrollBarImageColor3 = Color3.fromRGB(120, 40, 40)
    Content.CanvasSize = UDim2.new(0, 0, 0, 0)
    Content.AutomaticCanvasSize = Enum.AutomaticSize.Y
    Content.Parent = MainFrame

    -- Colors
    local C_CARD = Color3.fromRGB(40, 18, 18)
    local C_CARD_HOVER = Color3.fromRGB(55, 25, 25)
    local C_BORDER = Color3.fromRGB(80, 30, 30)
    local C_TITLE = Color3.fromRGB(255, 120, 120)
    local C_TEXT = Color3.fromRGB(200, 140, 140)
    local C_DIM = Color3.fromRGB(150, 90, 90)
    local C_GREEN = Color3.fromRGB(40, 120, 40)
    local C_RED = Color3.fromRGB(80, 25, 25)
    local C_PURPLE = Color3.fromRGB(120, 20, 120)
    local C_BLUE = Color3.fromRGB(35, 50, 120)
    local C_TEAL = Color3.fromRGB(20, 80, 80)
    local C_ORANGE = Color3.fromRGB(140, 70, 15)

    -- Helper: add page layout
    local function pageLayout(page)
        local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 4) l.SortOrder = Enum.SortOrder.LayoutOrder l.Parent = page
        local p = Instance.new("UIPadding") p.PaddingTop = UDim.new(0, 2) p.PaddingBottom = UDim.new(0, 4) p.Parent = page
    end

    -- Helper: page title
    local function pageTitle(page, text, order)
        local t = Instance.new("TextLabel")
        t.Text = text t.Size = UDim2.new(1, 0, 0, 20) t.BackgroundTransparency = 1
        t.TextColor3 = C_TITLE t.Font = Enum.Font.GothamBold t.TextSize = 13
        t.LayoutOrder = order or 1 t.Parent = page
        return t
    end

    -- Helper: back button
    local function createBack(parent, targetPage)
        local b = Instance.new("TextButton")
        b.Size = UDim2.new(0, 60, 0, 20) b.BackgroundColor3 = Color3.fromRGB(50, 20, 20) b.BorderSizePixel = 0
        b.Text = "BACK" b.TextColor3 = C_TEXT b.Font = Enum.Font.GothamBold b.TextSize = 9 b.Parent = parent
        Instance.new("UICorner", b).CornerRadius = UDim.new(0, 4)
        return b
    end

    -- Helper: toggle button
    local function createToggle(parent, text, color, order)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 28) btn.BackgroundColor3 = color btn.BorderSizePixel = 0
        btn.Text = text btn.TextColor3 = Color3.fromRGB(255, 255, 255) btn.Font = Enum.Font.GothamBold btn.TextSize = 11
        btn.LayoutOrder = order btn.Parent = parent
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        return btn
    end

    -- Helper: speed row
    local function createSpeedRow(parent, labelText, order, btnColor)
        local f = Instance.new("Frame")
        f.Size = UDim2.new(1, 0, 0, 22) f.BackgroundColor3 = Color3.fromRGB(35, 15, 15) f.BorderSizePixel = 0
        f.LayoutOrder = order f.Parent = parent
        Instance.new("UICorner", f).CornerRadius = UDim.new(0, 4)
        local lbl = Instance.new("TextLabel")
        lbl.Text = labelText lbl.Size = UDim2.new(0.55, 0, 1, 0) lbl.Position = UDim2.new(0, 5, 0, 0)
        lbl.BackgroundTransparency = 1 lbl.TextColor3 = C_TEXT lbl.Font = Enum.Font.Gotham lbl.TextSize = 10
        lbl.TextXAlignment = Enum.TextXAlignment.Left lbl.Parent = f
        local plus = Instance.new("TextButton")
        plus.Size = UDim2.new(0, 24, 0, 16) plus.Position = UDim2.new(1, -54, 0.5, -8)
        plus.BackgroundColor3 = btnColor plus.Text = "+" plus.TextColor3 = Color3.fromRGB(255, 255, 255)
        plus.Font = Enum.Font.GothamBold plus.TextSize = 11 plus.BorderSizePixel = 0 plus.Parent = f
        Instance.new("UICorner", plus).CornerRadius = UDim.new(0, 3)
        local minus = Instance.new("TextButton")
        minus.Size = UDim2.new(0, 24, 0, 16) minus.Position = UDim2.new(1, -28, 0.5, -8)
        minus.BackgroundColor3 = btnColor minus.Text = "-" minus.TextColor3 = Color3.fromRGB(255, 255, 255)
        minus.Font = Enum.Font.GothamBold minus.TextSize = 11 minus.BorderSizePixel = 0 minus.Parent = f
        Instance.new("UICorner", minus).CornerRadius = UDim.new(0, 3)
        return lbl, plus, minus
    end

    -- Helper: stats label
    local function statLabel(parent, text, order)
        local l = Instance.new("TextLabel")
        l.Text = text l.Size = UDim2.new(1, -12, 0, 15) l.BackgroundTransparency = 1
        l.TextColor3 = Color3.fromRGB(180, 120, 120) l.Font = Enum.Font.Gotham l.TextSize = 10
        l.TextXAlignment = Enum.TextXAlignment.Left l.Parent = parent
        return l
    end

    -- ============ PAGE: HOME ============
    local HomePage = Instance.new("Frame")
    HomePage.Size = UDim2.new(1, 0, 1, 0) HomePage.BackgroundTransparency = 1 HomePage.Parent = Content
    pageLayout(HomePage)
    do
        local hl = Instance.new("TextLabel")
        hl.Text = "SELECT" hl.Size = UDim2.new(1, 0, 0, 16) hl.BackgroundTransparency = 1
        hl.TextColor3 = C_DIM hl.Font = Enum.Font.Gotham hl.TextSize = 10 hl.LayoutOrder = 1 hl.Parent = HomePage
    end

    local function createTab(name, order)
        local btn = Instance.new("TextButton")
        btn.Size = UDim2.new(1, 0, 0, 38) btn.BackgroundColor3 = C_CARD btn.BorderSizePixel = 0
        btn.Text = name btn.TextColor3 = Color3.fromRGB(255, 200, 200) btn.Font = Enum.Font.GothamBold btn.TextSize = 12
        btn.LayoutOrder = order btn.Parent = HomePage
        Instance.new("UICorner", btn).CornerRadius = UDim.new(0, 6)
        do local s = Instance.new("UIStroke") s.Color = C_BORDER s.Thickness = 1 s.Parent = btn end
        btn.MouseEnter:Connect(function() btn.BackgroundColor3 = C_CARD_HOVER end)
        btn.MouseLeave:Connect(function() btn.BackgroundColor3 = C_CARD end)
        return btn
    end

    local oreTab = createTab("⛏️  ORE FARM", 2)
    local trashTab = createTab("🗑️  TRASH", 3)
    local othersTab = createTab("💪  OTHERS AUTO", 4)
    local moveTab = createTab("🚀  MOVEMENT", 5)
    local miscTab = createTab("⚙️  MISC", 6)
    local bindTab = createTab("⌨️  KEYBINDS", 7)

    -- ============ PAGE: ORE FARM ============
    local OrePage = Instance.new("Frame")
    OrePage.Size = UDim2.new(1, 0, 1, 0) OrePage.BackgroundTransparency = 1 OrePage.Visible = false OrePage.Parent = Content
    pageLayout(OrePage)
    local oreBack = createBack(OrePage)
    pageTitle(OrePage, "ORE FARM")
    local FarmBtn = createToggle(OrePage, "⛏️ START FARM", C_GREEN, 2)

    -- Stats frame
    local OreStatsFrame = Instance.new("Frame")
    OreStatsFrame.Size = UDim2.new(1, 0, 0, 72) OreStatsFrame.BackgroundColor3 = Color3.fromRGB(20, 10, 10)
    OreStatsFrame.BorderSizePixel = 0 OreStatsFrame.LayoutOrder = 3 OreStatsFrame.Parent = OrePage
    Instance.new("UICorner", OreStatsFrame).CornerRadius = UDim.new(0, 5)
    do local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 1) l.Parent = OreStatsFrame
       local p = Instance.new("UIPadding") p.PaddingTop = UDim.new(0, 3) p.PaddingLeft = UDim.new(0, 6) p.Parent = OreStatsFrame end

    local TimeLabel = statLabel(OreStatsFrame, "Time: 00:00:00")
    local OreLabel = statLabel(OreStatsFrame, "Ore: 0")
    local EarnLabel = statLabel(OreStatsFrame, "Earned: $0")
    local InvLabel = statLabel(OreStatsFrame, "Inv: 0 ore")

    local FarmStatusL = Instance.new("TextLabel")
    FarmStatusL.Text = "Status: Idle" FarmStatusL.Size = UDim2.new(1, 0, 0, 18)
    FarmStatusL.BackgroundColor3 = Color3.fromRGB(20, 10, 10) FarmStatusL.BorderSizePixel = 0
    FarmStatusL.TextColor3 = Color3.fromRGB(100, 200, 100) FarmStatusL.Font = Enum.Font.GothamBold FarmStatusL.TextSize = 10
    FarmStatusL.LayoutOrder = 4 FarmStatusL.Parent = OrePage
    Instance.new("UICorner", FarmStatusL).CornerRadius = UDim.new(0, 4)

    local SellBtn = createToggle(OrePage, "💰 SELL ALL", C_ORANGE, 5)

    -- ============ PAGE: TRASH FARM ============
    local TrashPage = Instance.new("Frame")
    TrashPage.Size = UDim2.new(1, 0, 1, 0) TrashPage.BackgroundTransparency = 1 TrashPage.Visible = false TrashPage.Parent = Content
    pageLayout(TrashPage)
    local trashBack = createBack(TrashPage)
    pageTitle(TrashPage, "TRASH COLLECTOR")

    local TrashFarmBtn = createToggle(TrashPage, "🗑️ START TRASH FARM", C_GREEN, 2)
    local SetBinBtn = createToggle(TrashPage, "📍 SET BIN POS (stand at bin)", C_CARD, 3)
    do local s = Instance.new("UIStroke") s.Color = C_BORDER s.Thickness = 1 s.Parent = SetBinBtn end
    local SpamHeadBtn = createToggle(TrashPage, "🤪 SPAM HEAD/BLINK", C_PURPLE, 5)

    -- Trash stats
    local TrashStatsFrame = Instance.new("Frame")
    TrashStatsFrame.Size = UDim2.new(1, 0, 0, 72) TrashStatsFrame.BackgroundColor3 = Color3.fromRGB(20, 10, 10)
    TrashStatsFrame.BorderSizePixel = 0 TrashStatsFrame.LayoutOrder = 4 TrashStatsFrame.Parent = TrashPage
    Instance.new("UICorner", TrashStatsFrame).CornerRadius = UDim.new(0, 5)
    do local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 1) l.Parent = TrashStatsFrame
       local p = Instance.new("UIPadding") p.PaddingTop = UDim.new(0, 3) p.PaddingLeft = UDim.new(0, 6) p.Parent = TrashStatsFrame end

    local TrashCountLabel = statLabel(TrashStatsFrame, "Collected: 0")
    local TrashAvailLabel = statLabel(TrashStatsFrame, "Available: 0")
    local TrashEarnLabel = statLabel(TrashStatsFrame, "Earned: $0")
    local TrashBinLabel = statLabel(TrashStatsFrame, "Bin: -115, -54, -408")

    -- ============ PAGE: OTHERS AUTO ============
    local OthersPage = Instance.new("Frame")
    OthersPage.Size = UDim2.new(1, 0, 1, 0) OthersPage.BackgroundTransparency = 1 OthersPage.Visible = false OthersPage.Parent = Content
    pageLayout(OthersPage)
    local othersBack = createBack(OthersPage)
    pageTitle(OthersPage, "OTHERS AUTO")

    local armTabBtn = createToggle(OthersPage, "💪 ARM WRESTLE", C_CARD, 2)
    do local s = Instance.new("UIStroke") s.Color = C_BORDER s.Thickness = 1 s.Parent = armTabBtn end
    local pullUpTabBtn = createToggle(OthersPage, "🏋️ PULL-UP BAR", C_CARD, 3)
    do local s = Instance.new("UIStroke") s.Color = C_BORDER s.Thickness = 1 s.Parent = pullUpTabBtn end

    -- ============ PAGE: ARM WRESTLE (sub of OTHERS) ============
    local ArmPage = Instance.new("Frame")
    ArmPage.Size = UDim2.new(1, 0, 1, 0) ArmPage.BackgroundTransparency = 1 ArmPage.Visible = false ArmPage.Parent = Content
    pageLayout(ArmPage)
    local armBack = createBack(ArmPage)
    pageTitle(ArmPage, "ARM WRESTLE")
    local AwAutoBtn = createToggle(ArmPage, "💪 AUTO: OFF", C_RED, 2)
    local AwSuperBtn = createToggle(ArmPage, "⚡ SUPER FAST: OFF", C_PURPLE, 3)
    local awNormLbl, awNormPlus, awNormMinus = createSpeedRow(ArmPage, "Delay: " .. string.format("%.2f", S.awNormalDelay) .. "s", 4, Color3.fromRGB(55, 20, 15))
    local awSupLbl, awSupPlus, awSupMinus = createSpeedRow(ArmPage, "Power: " .. S.awSuperFiresPF .. "/frame", 5, Color3.fromRGB(45, 15, 40))

    do
        local AwStatusFrame = Instance.new("Frame")
        AwStatusFrame.Size = UDim2.new(1, 0, 0, 32) AwStatusFrame.BackgroundColor3 = Color3.fromRGB(20, 10, 10)
        AwStatusFrame.BorderSizePixel = 0 AwStatusFrame.LayoutOrder = 6 AwStatusFrame.Parent = ArmPage
        Instance.new("UICorner", AwStatusFrame).CornerRadius = UDim.new(0, 4)
        do local l = Instance.new("UIListLayout") l.Padding = UDim.new(0, 1) l.Parent = AwStatusFrame
           local p = Instance.new("UIPadding") p.PaddingTop = UDim.new(0, 2) p.PaddingLeft = UDim.new(0, 6) p.Parent = AwStatusFrame end
        local ml = Instance.new("TextLabel")
        ml.Text = "Match: idle" ml.Size = UDim2.new(1, -12, 0, 13) ml.BackgroundTransparency = 1
        ml.TextColor3 = Color3.fromRGB(180, 120, 140) ml.Font = Enum.Font.Gotham ml.TextSize = 9
        ml.TextXAlignment = Enum.TextXAlignment.Left ml.Parent = AwStatusFrame
        local sl = Instance.new("TextLabel")
        sl.Text = "Waiting for match..." sl.Size = UDim2.new(1, -12, 0, 13) sl.BackgroundTransparency = 1
        sl.TextColor3 = Color3.fromRGB(100, 200, 100) sl.Font = Enum.Font.GothamBold sl.TextSize = 9
        sl.TextXAlignment = Enum.TextXAlignment.Left sl.Parent = AwStatusFrame
        S.Buttons.AwMatchLabel = ml
        S.Buttons.AwStatusLabel = sl
    end

    -- ============ PAGE: PULL-UP BAR (sub of OTHERS) ============
    local PullUpPage = Instance.new("Frame")
    PullUpPage.Size = UDim2.new(1, 0, 1, 0) PullUpPage.BackgroundTransparency = 1 PullUpPage.Visible = false PullUpPage.Parent = Content
    pageLayout(PullUpPage)
    local pullUpBack = createBack(PullUpPage)
    pageTitle(PullUpPage, "PULL-UP BAR")
    local PullUpBtn = createToggle(PullUpPage, "🏋️ AUTO PULL-UP: OFF", C_RED, 2)
    local AutoClimbBtn = createToggle(PullUpPage, "🧗 AUTO CLIMB: OFF", C_TEAL, 3)

    local PUStatusL = Instance.new("TextLabel")
    PUStatusL.Text = "Status: Idle" PUStatusL.Size = UDim2.new(1, 0, 0, 18)
    PUStatusL.BackgroundColor3 = Color3.fromRGB(20, 10, 10) PUStatusL.BorderSizePixel = 0
    PUStatusL.TextColor3 = Color3.fromRGB(180, 120, 120) PUStatusL.Font = Enum.Font.GothamBold PUStatusL.TextSize = 10
    PUStatusL.LayoutOrder = 4 PUStatusL.Parent = PullUpPage
    Instance.new("UICorner", PUStatusL).CornerRadius = UDim.new(0, 4)

    local PUCyclesL = statLabel(PullUpPage, "Cycles: 0", 5)

    -- Configurable click delay (seconds after circle appears before clicking)
    local puDelayLbl, puDelayPlus, puDelayMinus = createSpeedRow(PullUpPage, "Delay: " .. string.format("%.1f", S.pullUpClickDelay) .. "s", 6, Color3.fromRGB(55, 20, 15))

    do local h = Instance.new("TextLabel") h.Text = "Too early = increase delay. Too late = decrease." h.Size = UDim2.new(1, 0, 0, 14)
       h.BackgroundTransparency = 1 h.TextColor3 = Color3.fromRGB(100, 70, 70) h.Font = Enum.Font.Gotham
       h.TextSize = 8 h.LayoutOrder = 7 h.Parent = PullUpPage end



    -- ============ PAGE: MOVEMENT ============
    local MovePage = Instance.new("Frame")
    MovePage.Size = UDim2.new(1, 0, 1, 0) MovePage.BackgroundTransparency = 1 MovePage.Visible = false MovePage.Parent = Content
    pageLayout(MovePage)
    local moveBack = createBack(MovePage)
    pageTitle(MovePage, "MOVEMENT")
    local FlyBtn = createToggle(MovePage, "👤 FLY: OFF", C_BLUE, 2)
    local flySpeedLbl, flySpPlus, flySpMinus = createSpeedRow(MovePage, "Speed: " .. S.flySpeed, 3, Color3.fromRGB(30, 20, 45))
    local NoclipBtn = createToggle(MovePage, "💻 NOCLIP: OFF", C_RED, 4)
    local InvisBtn = createToggle(MovePage, "👻 INVISIBLE: OFF", C_TEAL, 5)
    do local h = Instance.new("TextLabel") h.Text = "WASD + Space/Shift to fly" h.Size = UDim2.new(1, 0, 0, 14)
       h.BackgroundTransparency = 1 h.TextColor3 = Color3.fromRGB(100, 70, 70) h.Font = Enum.Font.Gotham
       h.TextSize = 8 h.LayoutOrder = 6 h.Parent = MovePage end

    -- ============ PAGE: MISC ============
    local MiscPage = Instance.new("Frame")
    MiscPage.Size = UDim2.new(1, 0, 1, 0) MiscPage.BackgroundTransparency = 1 MiscPage.Visible = false MiscPage.Parent = Content
    pageLayout(MiscPage)
    local miscBack = createBack(MiscPage)
    pageTitle(MiscPage, "MISC")
    local NoFallBtn = createToggle(MiscPage, "❤️ NO FALL DMG: OFF", C_RED, 2)
    local AntiAFKBtn = createToggle(MiscPage, "🛡️ ANTI-AFK: OFF", C_RED, 3)
    local HungerBtn = createToggle(MiscPage, "🍖 INF HUNGER/THIRST: OFF", C_RED, 4)
    local DumpBtn = createToggle(MiscPage, "🔍 DUMP GAME VALUES", C_PURPLE, 5)
    do local h = Instance.new("TextLabel") h.Text = "Dump prints all values to F9 console" h.Size = UDim2.new(1, 0, 0, 14)
       h.BackgroundTransparency = 1 h.TextColor3 = Color3.fromRGB(100, 70, 70) h.Font = Enum.Font.Gotham
       h.TextSize = 8 h.LayoutOrder = 6 h.Parent = MiscPage end

    -- ============ PAGE: KEYBINDS ============
    local BindPage = Instance.new("Frame")
    BindPage.Size = UDim2.new(1, 0, 1, 0) BindPage.BackgroundTransparency = 1 BindPage.Visible = false BindPage.Parent = Content
    pageLayout(BindPage)
    local bindBack = createBack(BindPage)
    pageTitle(BindPage, "KEYBINDS")
    do local h = Instance.new("TextLabel") h.Text = "Click SET then press a key" h.Size = UDim2.new(1, 0, 0, 14)
       h.BackgroundTransparency = 1 h.TextColor3 = C_DIM h.Font = Enum.Font.Gotham h.TextSize = 8
       h.LayoutOrder = 2 h.Parent = BindPage end

    local bindableFuncs = {
        {name = "Arm Wrestle", id = "armwrestle", order = 3},
        {name = "Fly", id = "fly", order = 4},
        {name = "Invisible", id = "invis", order = 5},
        {name = "Noclip", id = "noclip", order = 6},
        {name = "Farm", id = "farm", order = 7},
        {name = "Pull-Up", id = "pullup", order = 8},
    }

    local bindRows = {}
    for _, func in ipairs(bindableFuncs) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, 0, 0, 24) row.BackgroundColor3 = Color3.fromRGB(35, 15, 15)
        row.BorderSizePixel = 0 row.LayoutOrder = func.order row.Parent = BindPage
        Instance.new("UICorner", row).CornerRadius = UDim.new(0, 4)
        local nl = Instance.new("TextLabel")
        nl.Text = func.name nl.Size = UDim2.new(0.35, 0, 1, 0) nl.Position = UDim2.new(0, 5, 0, 0)
        nl.BackgroundTransparency = 1 nl.TextColor3 = C_TEXT nl.Font = Enum.Font.GothamBold nl.TextSize = 10
        nl.TextXAlignment = Enum.TextXAlignment.Left nl.Parent = row
        local kl = Instance.new("TextLabel")
        kl.Text = "none" kl.Size = UDim2.new(0.25, 0, 1, 0) kl.Position = UDim2.new(0.35, 0, 0, 0)
        kl.BackgroundTransparency = 1 kl.TextColor3 = C_TITLE kl.Font = Enum.Font.GothamBold kl.TextSize = 10 kl.Parent = row
        local sb = Instance.new("TextButton")
        sb.Size = UDim2.new(0, 30, 0, 18) sb.Position = UDim2.new(0.62, 0, 0.5, -9)
        sb.BackgroundColor3 = Color3.fromRGB(50, 30, 30) sb.Text = "SET" sb.TextColor3 = Color3.fromRGB(255, 255, 255)
        sb.Font = Enum.Font.GothamBold sb.TextSize = 8 sb.BorderSizePixel = 0 sb.Parent = row
        Instance.new("UICorner", sb).CornerRadius = UDim.new(0, 3)
        local cb = Instance.new("TextButton")
        cb.Size = UDim2.new(0, 30, 0, 18) cb.Position = UDim2.new(1, -34, 0.5, -9)
        cb.BackgroundColor3 = Color3.fromRGB(80, 25, 25) cb.Text = "DEL" cb.TextColor3 = Color3.fromRGB(255, 255, 255)
        cb.Font = Enum.Font.GothamBold cb.TextSize = 8 cb.BorderSizePixel = 0 cb.Parent = row
        Instance.new("UICorner", cb).CornerRadius = UDim.new(0, 3)
        table.insert(bindRows, { id = func.id, keyLabel = kl, setBtn = sb, clearBtn = cb })
    end

    local bindListenLabel = Instance.new("TextLabel")
    bindListenLabel.Text = "" bindListenLabel.Size = UDim2.new(1, 0, 0, 16) bindListenLabel.BackgroundTransparency = 1
    bindListenLabel.TextColor3 = Color3.fromRGB(255, 200, 100) bindListenLabel.Font = Enum.Font.GothamBold
    bindListenLabel.TextSize = 9 bindListenLabel.LayoutOrder = 100 bindListenLabel.Parent = BindPage

    -- Store pages
    S.Pages = {
        Home = HomePage, Ore = OrePage, Trash = TrashPage, Others = OthersPage,
        Arm = ArmPage, PullUp = PullUpPage, Move = MovePage,
        Misc = MiscPage, Bind = BindPage
    }

    -- ============ PAGE NAVIGATION ============
    local function showPage(name)
        for pname, page in pairs(S.Pages) do page.Visible = (pname == name) end
    end

    oreTab.MouseButton1Click:Connect(function() showPage("Ore") end)
    trashTab.MouseButton1Click:Connect(function() showPage("Trash") end)
    othersTab.MouseButton1Click:Connect(function() showPage("Others") end)
    moveTab.MouseButton1Click:Connect(function() showPage("Move") end)
    miscTab.MouseButton1Click:Connect(function() showPage("Misc") end)
    bindTab.MouseButton1Click:Connect(function() showPage("Bind") end)

    -- Sub-navigation from OTHERS AUTO
    armTabBtn.MouseButton1Click:Connect(function() showPage("Arm") end)
    pullUpTabBtn.MouseButton1Click:Connect(function() showPage("PullUp") end)

    -- Back buttons
    oreBack.MouseButton1Click:Connect(function() showPage("Home") end)
    trashBack.MouseButton1Click:Connect(function() showPage("Home") end)
    othersBack.MouseButton1Click:Connect(function() showPage("Home") end)
    armBack.MouseButton1Click:Connect(function() showPage("Others") end)
    pullUpBack.MouseButton1Click:Connect(function() showPage("Others") end)
    moveBack.MouseButton1Click:Connect(function() showPage("Home") end)
    miscBack.MouseButton1Click:Connect(function() showPage("Home") end)
    bindBack.MouseButton1Click:Connect(function() showPage("Home") end)

    -- Hide / Close / MinBtn
    S.Buttons.HideBtn.MouseButton1Click:Connect(function()
        MainFrame.Visible = false
        MinBtn.Visible = true
        isMinimized = true
    end)
    MinBtn.MouseButton1Click:Connect(function()
        MainFrame.Visible = true
        MinBtn.Visible = false
        isMinimized = false
    end)
    -- Close button with "Are you sure?" confirmation
    local confirmFrame = nil
    S.Buttons.CloseBtn.MouseButton1Click:Connect(function()
        if confirmFrame and confirmFrame.Parent then return end -- already showing
        confirmFrame = Instance.new("Frame")
        confirmFrame.Name = "CloseConfirm"
        confirmFrame.Size = UDim2.new(0, 160, 0, 70)
        confirmFrame.Position = UDim2.new(0.5, -80, 0.5, -35)
        confirmFrame.BackgroundColor3 = Color3.fromRGB(40, 10, 10)
        confirmFrame.BorderSizePixel = 0
        confirmFrame.Parent = MainFrame
        Instance.new("UICorner", confirmFrame).CornerRadius = UDim.new(0, 8)
        do local s = Instance.new("UIStroke") s.Color = Color3.fromRGB(180, 60, 60) s.Thickness = 1.5 s.Parent = confirmFrame end

        local qLabel = Instance.new("TextLabel")
        qLabel.Text = "Are you sure?"
        qLabel.Size = UDim2.new(1, 0, 0, 24)
        qLabel.Position = UDim2.new(0, 0, 0, 6)
        qLabel.BackgroundTransparency = 1
        qLabel.TextColor3 = Color3.fromRGB(255, 200, 200)
        qLabel.Font = Enum.Font.GothamBold qLabel.TextSize = 12
        qLabel.Parent = confirmFrame

        local yesBtn = Instance.new("TextButton")
        yesBtn.Size = UDim2.new(0, 60, 0, 24)
        yesBtn.Position = UDim2.new(0, 14, 1, -32)
        yesBtn.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
        yesBtn.Text = "YES"
        yesBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        yesBtn.Font = Enum.Font.GothamBold yesBtn.TextSize = 10 yesBtn.BorderSizePixel = 0
        yesBtn.Parent = confirmFrame
        Instance.new("UICorner", yesBtn).CornerRadius = UDim.new(0, 4)

        local noBtn = Instance.new("TextButton")
        noBtn.Size = UDim2.new(0, 60, 0, 24)
        noBtn.Position = UDim2.new(1, -74, 1, -32)
        noBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 50)
        noBtn.Text = "NO"
        noBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
        noBtn.Font = Enum.Font.GothamBold noBtn.TextSize = 10 noBtn.BorderSizePixel = 0
        noBtn.Parent = confirmFrame
        Instance.new("UICorner", noBtn).CornerRadius = UDim.new(0, 4)

        yesBtn.MouseButton1Click:Connect(function()
            ScreenGui:Destroy()
        end)
        noBtn.MouseButton1Click:Connect(function()
            if confirmFrame and confirmFrame.Parent then confirmFrame:Destroy() end
            confirmFrame = nil
        end)
    end)

    -- ============ ORE FARM BUTTONS ============
    FarmBtn.MouseButton1Click:Connect(function()
        if S.isFarming then
            S.stopFarming()
            FarmBtn.Text = "⛏️ START FARM"
            FarmBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Farm: OFF")
        else
            S.startFarming()
            FarmBtn.Text = "⛏️ STOP FARM"
            FarmBtn.BackgroundColor3 = C_RED
            S.sendNotif("Farm: ON")
        end
    end)

    SellBtn.MouseButton1Click:Connect(function() S.sellAllOre() end)

    -- ============ TRASH FARM BUTTONS ============
    TrashFarmBtn.MouseButton1Click:Connect(function()
        if S.isTrashFarming then
            S.stopTrashFarm()
            TrashFarmBtn.Text = "🗑️ START TRASH FARM"
            TrashFarmBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Trash Farm: OFF")
        else
            S.startTrashFarm()
            TrashFarmBtn.Text = "🗑️ STOP TRASH FARM"
            TrashFarmBtn.BackgroundColor3 = C_RED
            S.sendNotif("Trash Farm: ON")
        end
    end)

    SetBinBtn.MouseButton1Click:Connect(function()
        local hrp = S.getHRP()
        if hrp then
            S.trashBinPos = hrp.Position
            TrashBinLabel.Text = "Bin: " .. math.floor(S.trashBinPos.X) .. ", " .. math.floor(S.trashBinPos.Y) .. ", " .. math.floor(S.trashBinPos.Z)
            S.sendNotif("Bin position set!")
            SetBinBtn.Text = "📍 BIN POS SET ✓"
        end
    end)

    SpamHeadBtn.MouseButton1Click:Connect(function()
        S.toggleSpamHead(not S.isSpammingHead)
        if S.isSpammingHead then
            SpamHeadBtn.Text = "🤪 SPAM HEAD: ON" SpamHeadBtn.BackgroundColor3 = C_RED
        else
            SpamHeadBtn.Text = "🤪 SPAM HEAD/BLINK" SpamHeadBtn.BackgroundColor3 = C_PURPLE
        end
    end)

    -- ============ ARM WRESTLE BUTTONS ============
    AwAutoBtn.MouseButton1Click:Connect(function()
        S.awAutoEnabled = not S.awAutoEnabled
        if S.awAutoEnabled then
            AwAutoBtn.Text = "💪 AUTO: ON" AwAutoBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Arm Wrestle: ON")
            if S.awMatchActive and S.awCurrentRemote then
                if S.awSuperFastMode then S.awStartSuperFast() else S.awStartNormalSpam() end
            end
        else
            AwAutoBtn.Text = "💪 AUTO: OFF" AwAutoBtn.BackgroundColor3 = C_RED
            S.sendNotif("Arm Wrestle: OFF")
            S.awStopAll()
        end
    end)

    AwSuperBtn.MouseButton1Click:Connect(function()
        S.awSuperFastMode = not S.awSuperFastMode
        if S.awSuperFastMode then
            AwSuperBtn.Text = "⚡ SUPER FAST: ON" AwSuperBtn.BackgroundColor3 = Color3.fromRGB(180, 30, 180)
            S.sendNotif("Super Fast: ON")
        else
            AwSuperBtn.Text = "⚡ SUPER FAST: OFF" AwSuperBtn.BackgroundColor3 = C_PURPLE
            S.sendNotif("Super Fast: OFF")
        end
    end)

    awNormPlus.MouseButton1Click:Connect(function()
        S.awNormalDelay = math.min(S.awNormalDelay + 0.02, 0.50)
        awNormLbl.Text = "Delay: " .. string.format("%.2f", S.awNormalDelay) .. "s"
    end)
    awNormMinus.MouseButton1Click:Connect(function()
        S.awNormalDelay = math.max(S.awNormalDelay - 0.02, 0.02)
        awNormLbl.Text = "Delay: " .. string.format("%.2f", S.awNormalDelay) .. "s"
    end)
    awSupPlus.MouseButton1Click:Connect(function()
        S.awSuperFiresPF = math.min(S.awSuperFiresPF + 1, 10)
        awSupLbl.Text = "Power: " .. S.awSuperFiresPF .. "/frame"
    end)
    awSupMinus.MouseButton1Click:Connect(function()
        S.awSuperFiresPF = math.max(S.awSuperFiresPF - 1, 1)
        awSupLbl.Text = "Power: " .. S.awSuperFiresPF .. "/frame"
    end)

    -- ============ PULL-UP BAR BUTTONS ============
    PullUpBtn.MouseButton1Click:Connect(function()
        if S.isPullUpActive then
            S.stopPullUp()
            PullUpBtn.Text = "🏋️ AUTO PULL-UP: OFF" PullUpBtn.BackgroundColor3 = C_RED
            AutoClimbBtn.Text = "🧗 AUTO CLIMB: OFF" AutoClimbBtn.BackgroundColor3 = C_TEAL
            S.sendNotif("Pull-Up: OFF")
        else
            S.startPullUp()
            PullUpBtn.Text = "🏋️ AUTO PULL-UP: ON" PullUpBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Pull-Up: ON")
        end
    end)

    AutoClimbBtn.MouseButton1Click:Connect(function()
        S.pullUpAutoClimb = not S.pullUpAutoClimb
        if S.pullUpAutoClimb then
            AutoClimbBtn.Text = "🧗 AUTO CLIMB: ON" AutoClimbBtn.BackgroundColor3 = Color3.fromRGB(20, 120, 120)
            S.sendNotif("Auto Climb: ON")
        else
            AutoClimbBtn.Text = "🧗 AUTO CLIMB: OFF" AutoClimbBtn.BackgroundColor3 = C_TEAL
            S.sendNotif("Auto Climb: OFF")
        end
    end)

    -- Pull-Up delay controls
    puDelayPlus.MouseButton1Click:Connect(function()
        S.pullUpClickDelay = math.min(S.pullUpClickDelay + 0.1, 5.0)
        puDelayLbl.Text = "Delay: " .. string.format("%.1f", S.pullUpClickDelay) .. "s"
    end)
    puDelayMinus.MouseButton1Click:Connect(function()
        S.pullUpClickDelay = math.max(S.pullUpClickDelay - 0.1, 0.1)
        puDelayLbl.Text = "Delay: " .. string.format("%.1f", S.pullUpClickDelay) .. "s"
    end)



    -- ============ MOVEMENT BUTTONS ============
    FlyBtn.MouseButton1Click:Connect(function()
        S.toggleFly()
        if S.isFlying then
            FlyBtn.Text = "👤 FLY: ON" FlyBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 160)
            S.sendNotif("Fly: ON")
        else
            FlyBtn.Text = "👤 FLY: OFF" FlyBtn.BackgroundColor3 = C_BLUE
            S.sendNotif("Fly: OFF")
        end
    end)

    flySpPlus.MouseButton1Click:Connect(function()
        S.flySpeed = math.min(S.flySpeed + 20, 400)
        flySpeedLbl.Text = "Speed: " .. S.flySpeed
    end)
    flySpMinus.MouseButton1Click:Connect(function()
        S.flySpeed = math.max(S.flySpeed - 20, 20)
        flySpeedLbl.Text = "Speed: " .. S.flySpeed
    end)

    NoclipBtn.MouseButton1Click:Connect(function()
        S.toggleNoclip(not S.isNoclipping)
        if S.isNoclipping then
            NoclipBtn.Text = "💻 NOCLIP: ON" NoclipBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Noclip: ON")
        else
            NoclipBtn.Text = "💻 NOCLIP: OFF" NoclipBtn.BackgroundColor3 = C_RED
            S.sendNotif("Noclip: OFF")
        end
    end)

    InvisBtn.MouseButton1Click:Connect(function()
        S.toggleInvisibility(not S.isInvisible)
        if S.isInvisible then
            InvisBtn.Text = "👻 INVISIBLE: ON" InvisBtn.BackgroundColor3 = Color3.fromRGB(30, 140, 140)
            S.sendNotif("Invisible: ON")
        else
            InvisBtn.Text = "👻 INVISIBLE: OFF" InvisBtn.BackgroundColor3 = C_TEAL
            S.sendNotif("Invisible: OFF")
        end
    end)

    -- ============ INFINITE HUNGER/THIRST ============
    do
        local foundHungerValues = {}  -- cached after dump

        function S.dumpGameValues()
            foundHungerValues = {}
            print("========================================")
            print("[AI DUMP] Scanning game for ALL values...")
            print("========================================")

            -- 1. PlayerGui
            pcall(function()
                local pg = S.LocalPlayer:FindFirstChild("PlayerGui")
                if pg then
                    print("[AI DUMP] === PlayerGui ===")
                    for _, desc in ipairs(pg:GetDescendants()) do
                        if desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("FloatValue") or desc:IsA("DoubleConstrainedValue") then
                            print("[AI DUMP]   " .. desc:GetFullName() .. " = " .. tostring(desc.Value))
                        end
                    end
                    -- Attributes on PlayerGui elements
                    for _, desc in ipairs(pg:GetDescendants()) do
                        local attrs = desc:GetAttributes()
                        if next(attrs) then
                            for k, v in pairs(attrs) do
                                if type(v) == "number" then
                                    print("[AI DUMP]   ATTR " .. desc:GetFullName() .. " ." .. k .. " = " .. tostring(v))
                                end
                            end
                        end
                    end
                end
            end)

            -- 2. Character
            pcall(function()
                local char = S.getCharacter()
                if char then
                    print("[AI DUMP] === Character ===")
                    for _, desc in ipairs(char:GetDescendants()) do
                        if desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("FloatValue") or desc:IsA("DoubleConstrainedValue") then
                            print("[AI DUMP]   " .. desc:GetFullName() .. " = " .. tostring(desc.Value))
                            table.insert(foundHungerValues, desc)
                        end
                    end
                    -- Humanoid attributes
                    local hum = char:FindFirstChildOfClass("Humanoid")
                    if hum then
                        local attrs = hum:GetAttributes()
                        if next(attrs) then
                            print("[AI DUMP] === Humanoid Attributes ===")
                            for k, v in pairs(attrs) do
                                print("[AI DUMP]   Humanoid." .. k .. " = " .. tostring(v))
                            end
                        end
                    end
                    -- Attributes on all parts
                    for _, desc in ipairs(char:GetDescendants()) do
                        local attrs = desc:GetAttributes()
                        if next(attrs) then
                            for k, v in pairs(attrs) do
                                if type(v) == "number" then
                                    print("[AI DUMP]   ATTR " .. desc:GetFullName() .. " ." .. k .. " = " .. tostring(v))
                                end
                            end
                        end
                    end
                end
            end)

            -- 3. Player
            pcall(function()
                print("[AI DUMP] === Player ===")
                for _, desc in ipairs(S.LocalPlayer:GetDescendants()) do
                    if desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("FloatValue") or desc:IsA("DoubleConstrainedValue") then
                        print("[AI DUMP]   " .. desc:GetFullName() .. " = " .. tostring(desc.Value))
                        table.insert(foundHungerValues, desc)
                    end
                end
                local attrs = S.LocalPlayer:GetAttributes()
                if next(attrs) then
                    for k, v in pairs(attrs) do
                        print("[AI DUMP]   Player ATTR ." .. k .. " = " .. tostring(v))
                    end
                end
            end)

            -- 4. ReplicatedStorage
            pcall(function()
                print("[AI DUMP] === ReplicatedStorage (top 2 levels) ===")
                for _, child in ipairs(S.ReplicatedStorage:GetChildren()) do
                    print("[AI DUMP]   " .. child.Name .. " (" .. child.ClassName .. ")")
                    for _, desc in ipairs(child:GetChildren()) do
                        if desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("FloatValue") then
                            print("[AI DUMP]     " .. desc.Name .. " = " .. tostring(desc.Value))
                        end
                        if desc:IsA("RemoteEvent") or desc:IsA("RemoteFunction") then
                            print("[AI DUMP]     REMOTE: " .. desc.Name)
                        end
                    end
                end
            end)

            -- 5. Workspace > Tasks (game task objects)
            pcall(function()
                local tasks = S.Workspace:FindFirstChild("Tasks")
                if tasks then
                    print("[AI DUMP] === Workspace > Tasks ===")
                    for _, child in ipairs(tasks:GetChildren()) do
                        print("[AI DUMP]   " .. child.Name)
                    end
                end
            end)

            print("========================================")
            print("[AI DUMP] Done! Check F9 console.")
            print("[AI DUMP] Found " .. #foundHungerValues .. " numeric values total.")
            print("========================================")
        end

        function S.toggleInfiniteHunger(enable)
            if enable then
                S.isInfiniteHunger = true
                if S.hungerConn then S.hungerConn:Disconnect() end

                -- Auto-find Hunger/Thirst values every frame and max them
                S.hungerConn = S.RunService.Heartbeat:Connect(function()
                    if not S.isInfiniteHunger then return end
                    pcall(function()
                        -- Method 1: Search Player descendants for named values
                        for _, desc in ipairs(S.LocalPlayer:GetDescendants()) do
                            if (desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("FloatValue"))
                                and (desc.Name:lower():find("hunger") or desc.Name:lower():find("thirst") or desc.Name:lower():find("food") or desc.Name:lower():find("water")) then
                                pcall(function() desc.Value = 100 end)
                            end
                        end
                        -- Method 2: Search Character descendants
                        local char = S.getCharacter()
                        if char then
                            for _, desc in ipairs(char:GetDescendants()) do
                                if (desc:IsA("NumberValue") or desc:IsA("IntValue") or desc:IsA("FloatValue"))
                                    and (desc.Name:lower():find("hunger") or desc.Name:lower():find("thirst") or desc.Name:lower():find("food") or desc.Name:lower():find("water")) then
                                    pcall(function() desc.Value = 100 end)
                                end
                            end
                            -- Method 3: Humanoid attributes
                            local hum = char:FindFirstChildOfClass("Humanoid")
                            if hum then
                                for k, v in pairs(hum:GetAttributes()) do
                                    if type(v) == "number" and (k:lower():find("hunger") or k:lower():find("thirst") or k:lower():find("food") or k:lower():find("water")) then
                                        pcall(function() hum:SetAttribute(k, 100) end)
                                    end
                                end
                            end
                        end
                        -- Method 4: Also use any cached values from dump
                        for _, v in ipairs(foundHungerValues) do
                            if v and v.Parent then
                                pcall(function() v.Value = 100 end)
                            end
                        end
                    end)
                end)
            else
                S.isInfiniteHunger = false
                if S.hungerConn then
                    S.hungerConn:Disconnect()
                    S.hungerConn = nil
                end
            end
        end
    end

    -- ============ MISC BUTTONS ============
    NoFallBtn.MouseButton1Click:Connect(function()
        S.toggleNoFallDMG(not S.isNoFallDmg)
        if S.isNoFallDmg then
            NoFallBtn.Text = "❤️ NO FALL DMG: ON" NoFallBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("No Fall DMG: ON")
        else
            NoFallBtn.Text = "❤️ NO FALL DMG: OFF" NoFallBtn.BackgroundColor3 = C_RED
            S.sendNotif("No Fall DMG: OFF")
        end
    end)

    AntiAFKBtn.MouseButton1Click:Connect(function()
        if S.antiAFKConn then
            S.antiAFKConn:Disconnect(); S.antiAFKConn = nil
            AntiAFKBtn.Text = "🛡️ ANTI-AFK: OFF" AntiAFKBtn.BackgroundColor3 = C_RED
            S.sendNotif("Anti-AFK: OFF")
        else
            S.startAntiAFK()
            AntiAFKBtn.Text = "🛡️ ANTI-AFK: ON" AntiAFKBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Anti-AFK: ON")
        end
    end)

    HungerBtn.MouseButton1Click:Connect(function()
        S.toggleInfiniteHunger(not S.isInfiniteHunger)
        if S.isInfiniteHunger then
            HungerBtn.Text = "🍖 INF HUNGER/THIRST: ON" HungerBtn.BackgroundColor3 = C_GREEN
            S.sendNotif("Inf Hunger/Thirst: ON")
        else
            HungerBtn.Text = "🍖 INF HUNGER/THIRST: OFF" HungerBtn.BackgroundColor3 = C_RED
            S.sendNotif("Inf Hunger/Thirst: OFF")
        end
    end)

    DumpBtn.MouseButton1Click:Connect(function()
        S.dumpGameValues()
        S.sendNotif("Dumped! Check F9 console")
    end)

    -- ============ KEYBIND BUTTONS ============
    for _, br in ipairs(bindRows) do
        br.setBtn.MouseButton1Click:Connect(function()
            S.listeningForBind = br.id
            br.setBtn.BackgroundColor3 = Color3.fromRGB(160, 60, 20)
            br.setBtn.Text = "..."
            bindListenLabel.Text = "Press a key for " .. br.id .. "..."
        end)
        br.clearBtn.MouseButton1Click:Connect(function()
            S.keybinds[br.id] = nil
            br.keyLabel.Text = "none"
        end)
    end

    -- ============ KEYBIND INPUT HANDLER ============
    S.UserInputService.InputBegan:Connect(function(input, gpe)
        if gpe then return end
        if S.listeningForBind then
            local keyName = input.KeyCode.Name
            S.keybinds[S.listeningForBind] = input.KeyCode
            for _, br in ipairs(bindRows) do
                if br.id == S.listeningForBind then
                    br.keyLabel.Text = keyName
                    br.setBtn.BackgroundColor3 = Color3.fromRGB(50, 30, 30)
                    br.setBtn.Text = "SET"
                end
            end
            bindListenLabel.Text = ""
            S.listeningForBind = nil
            return
        end
        for _, br in ipairs(bindRows) do
            local bind = S.keybinds[br.id]
            if bind and input.KeyCode == bind then
                if br.id == "armwrestle" then
                    S.awAutoEnabled = not S.awAutoEnabled
                    if S.awAutoEnabled then
                        AwAutoBtn.Text = "💪 AUTO: ON" AwAutoBtn.BackgroundColor3 = C_GREEN
                        S.sendNotif("Arm Wrestle: ON")
                        if S.awMatchActive and S.awCurrentRemote then
                            if S.awSuperFastMode then S.awStartSuperFast() else S.awStartNormalSpam() end
                        end
                    else
                        AwAutoBtn.Text = "💪 AUTO: OFF" AwAutoBtn.BackgroundColor3 = C_RED
                        S.sendNotif("Arm Wrestle: OFF") S.awStopAll()
                    end
                elseif br.id == "fly" then
                    S.toggleFly()
                    if S.isFlying then FlyBtn.Text = "👤 FLY: ON" FlyBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 160) S.sendNotif("Fly: ON")
                    else FlyBtn.Text = "👤 FLY: OFF" FlyBtn.BackgroundColor3 = C_BLUE S.sendNotif("Fly: OFF") end
                elseif br.id == "invis" then
                    S.toggleInvisibility(not S.isInvisible)
                    if S.isInvisible then InvisBtn.Text = "👻 INVISIBLE: ON" InvisBtn.BackgroundColor3 = Color3.fromRGB(30, 140, 140) S.sendNotif("Invisible: ON")
                    else InvisBtn.Text = "👻 INVISIBLE: OFF" InvisBtn.BackgroundColor3 = C_TEAL S.sendNotif("Invisible: OFF") end
                elseif br.id == "noclip" then
                    S.toggleNoclip(not S.isNoclipping)
                    if S.isNoclipping then NoclipBtn.Text = "💻 NOCLIP: ON" NoclipBtn.BackgroundColor3 = C_GREEN S.sendNotif("Noclip: ON")
                    else NoclipBtn.Text = "💻 NOCLIP: OFF" NoclipBtn.BackgroundColor3 = C_RED S.sendNotif("Noclip: OFF") end
                elseif br.id == "farm" then
                    if S.isFarming then S.stopFarming() FarmBtn.Text = "⛏️ START FARM" FarmBtn.BackgroundColor3 = C_GREEN S.sendNotif("Farm: OFF")
                    else S.startFarming() FarmBtn.Text = "⛏️ STOP FARM" FarmBtn.BackgroundColor3 = C_RED S.sendNotif("Farm: ON") end
                elseif br.id == "pullup" then
                    if S.isPullUpActive then S.stopPullUp() PullUpBtn.Text = "🏋️ AUTO PULL-UP: OFF" PullUpBtn.BackgroundColor3 = C_RED AutoClimbBtn.Text = "🧗 AUTO CLIMB: OFF" AutoClimbBtn.BackgroundColor3 = C_TEAL S.sendNotif("Pull-Up: OFF")
                    else S.startPullUp() PullUpBtn.Text = "🏋️ AUTO PULL-UP: ON" PullUpBtn.BackgroundColor3 = C_GREEN S.sendNotif("Pull-Up: ON") end
                end
            end
        end
    end)

    -- ============ STATS UPDATER ============
    S.RunService.Heartbeat:Connect(function()
        if S.isFarming then
            TimeLabel.Text = "Time: " .. S.formatTime(tick() - S.farmStartTime)
            local inv = S.countInventoryItems()
            OreLabel.Text = "Ore: " .. S.currentSessionOre
            EarnLabel.Text = "Earned: $" .. S.currentSessionEarnings
            InvLabel.Text = "Inv: " .. S.getTotalOreCount(inv) .. " ore"
            FarmStatusL.Text = "Status: Mining..."
            FarmStatusL.TextColor3 = Color3.fromRGB(100, 200, 100)
        else
            if S.frozenTimeStr ~= "00:00:00" or S.frozenOreCount > 0 then
                TimeLabel.Text = "Time: " .. S.frozenTimeStr
                OreLabel.Text = "Ore: " .. S.frozenOreCount
                EarnLabel.Text = "Earned: $" .. S.frozenEarnings
            end
            FarmStatusL.Text = "Status: Idle"
            FarmStatusL.TextColor3 = Color3.fromRGB(180, 120, 120)
        end

        -- Arm wrestle status
        if S.Buttons.AwMatchLabel then
            S.Buttons.AwMatchLabel.Text = S.awMatchActive and "Match: active" or "Match: idle"
        end
        if S.Buttons.AwStatusLabel then
            if S.awMatchActive and S.awAutoEnabled then
                S.Buttons.AwStatusLabel.Text = "Auto-spamming..."
                S.Buttons.AwStatusLabel.TextColor3 = Color3.fromRGB(100, 200, 100)
            elseif S.awMatchActive and not S.awAutoEnabled then
                S.Buttons.AwStatusLabel.Text = "Match active (auto OFF)"
                S.Buttons.AwStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 100)
            else
                S.Buttons.AwStatusLabel.Text = "Waiting for match..."
                S.Buttons.AwStatusLabel.TextColor3 = Color3.fromRGB(100, 200, 100)
            end
        end

        -- Pull-up status (with delay display)
        if S.isPullUpActive then
            PUStatusL.Text = "Status: " .. (S.pullUpOnBar and "Playing" or "Waiting") .. " | Delay: " .. string.format("%.1f", S.pullUpClickDelay) .. "s"
            PUStatusL.TextColor3 = Color3.fromRGB(100, 200, 100)
            PUCyclesL.Text = "Cycles: " .. S.pullUpCycles .. " | Score: " .. (S.pullUpScore or 0)
        else
            PUStatusL.Text = "Status: Idle"
            PUStatusL.TextColor3 = Color3.fromRGB(180, 120, 120)
        end

        -- Trash farm stats
        TrashCountLabel.Text = "Collected: " .. S.trashCollected
        TrashAvailLabel.Text = "Available: " .. S.trashTotal
        TrashEarnLabel.Text = "Earned: $" .. S.trashEarnings
        if S.trashBinPos then
            TrashBinLabel.Text = "Bin: " .. math.floor(S.trashBinPos.X) .. ", " .. math.floor(S.trashBinPos.Y) .. ", " .. math.floor(S.trashBinPos.Z)
        else
            TrashBinLabel.Text = "Bin: not set"
        end
    end)
end
