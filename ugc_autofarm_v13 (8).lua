--[[
    AI Script v0.01
    Game: UGC Prison (Place ID: 102718061120016)
    Features: Ore Farm, Fly, Noclip, No Fall DMG, Anti-AFK
]]

--// SERVICES
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local VirtualUser = game:GetService("VirtualUser")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

--// PLAYER
local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local HumanoidRootPart = Character:WaitForChild("HumanoidRootPart")

--// CONSTANTS
local CAVE_POS = Vector3.new(-424, -8, 246)
local ROCKS_PARENT_PATH = "Tasks.Prisoner.Rocks"
local MINERAL_BUYER_NAME = "Mineral Buyer"
local MINING_DISTANCE = 5
local HIT_INTERVAL = 0.45
local SELL_INTERVAL = 2

--// Ore Prices
local ORE_PRICES = {
    Azurith = 54,
    RawGold = 24,
    RawIron = 11,
    RawCopper = 5,
    Coal = 4
}

--// STATE
local isFlying = false
local isNoclipping = false
local isNoFallDmg = false
local isFarming = false
local farmStartTime = 0
local frozenTimeStr = "00:00:00"
local frozenOreCount = 0
local frozenEarnings = 0
local totalOreMined = 0
local totalEarnings = 0
local currentSessionOre = 0
local currentSessionEarnings = 0
local minedRocks = {}
local lastRockPosition = nil

--// Fly State (IY-style)
local flySpeed = 80
local flyBodyVelocity = nil
local flyBodyGyro = nil
local flyConn = nil
local noclipConn = nil
local noFallConn = nil
local platformPart = nil

--// Anti-AFK
local antiAFKConn = nil

--// ============================================================
--// UTILITY FUNCTIONS
--// ============================================================

local function getCharacter()
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") then
        return char
    end
    return nil
end

local function getHRP()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getHumanoid()
    local char = getCharacter()
    return char and char:FindFirstChildOfClass("Humanoid")
end

local function getToolEvent()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return nil end
    local toolFolder = remotes:FindFirstChild("Tool")
    if not toolFolder then return nil end
    return toolFolder:FindFirstChild("Event")
end

local function getSellRemote()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    if not remotes then return nil end
    return remotes:FindFirstChild("SellOre")
end

local function getMineralBuyer()
    local entities = Workspace:FindFirstChild("Entities")
    if not entities then return nil end
    return entities:FindFirstChild(MINERAL_BUYER_NAME)
end

local function getRocksParent()
    local tasks = Workspace:FindFirstChild("Tasks")
    if not tasks then return nil end
    local prisoner = tasks:FindFirstChild("Prisoner")
    if not prisoner then return nil end
    return prisoner:FindFirstChild("Rocks")
end

local function countInventoryItems()
    local char = getCharacter()
    if not char then return {} end
    local backpack = LocalPlayer:FindFirstChild("Backpack")
    local counts = {}
    for oreName, _ in pairs(ORE_PRICES) do
        counts[oreName] = 0
    end
    -- Check Backpack
    if backpack then
        for _, item in ipairs(backpack:GetChildren()) do
            if ORE_PRICES[item.Name] then
                counts[item.Name] = counts[item.Name] + 1
            end
        end
    end
    -- Check Character (held items)
    if char then
        for _, item in ipairs(char:GetChildren()) do
            if ORE_PRICES[item.Name] then
                counts[item.Name] = counts[item.Name] + 1
            end
        end
    end
    return counts
end

local function getTotalOreCount(inventory)
    local total = 0
    for _, count in pairs(inventory) do
        total = total + count
    end
    return total
end

local function calculateEarnings(inventory)
    local total = 0
    for oreName, count in pairs(inventory) do
        if ORE_PRICES[oreName] then
            total = total + (count * ORE_PRICES[oreName])
        end
    end
    return total
end

local function formatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    return string.format("%02d:%02d:%02d", h, m, s)
end

local function isRockValid(rock)
    if not rock then return false end
    if rock.Parent == nil then return false end
    if not Workspace:IsAncestorOf(rock) then return false end
    if not rock:IsA("BasePart") then return false end
    return true
end

local function findNearestRock(skipList)
    skipList = skipList or {}
    local rocksParent = getRocksParent()
    if not rocksParent then return nil end

    local hrp = getHRP()
    if not hrp then return nil end

    local nearest = nil
    local nearestDist = math.huge

    for _, rock in ipairs(rocksParent:GetChildren()) do
        if isRockValid(rock) then
            -- Skip already mined rocks
            local skip = false
            for _, skipped in ipairs(skipList) do
                if skipped == rock then
                    skip = true
                    break
                end
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

--// ============================================================
--// PLATFORM (anti-fall while mining)
--// ============================================================

local function removePlatform()
    if platformPart then
        pcall(function() platformPart:Destroy() end)
        platformPart = nil
    end
end

local function movePlatformTo(position)
    if platformPart and platformPart.Parent then
        platformPart.Position = position - Vector3.new(0, 3.5, 0)
    end
end

local function createPlatform(position)
    removePlatform()
    local success = pcall(function()
        platformPart = Instance.new("Part")
        platformPart.Name = "AIPlatform"
        platformPart.Size = Vector3.new(12, 1, 12)
        platformPart.Position = position - Vector3.new(0, 3.5, 0)
        platformPart.Anchored = true
        platformPart.CanCollide = true
        platformPart.Material = Enum.Material.ForceField
        platformPart.Transparency = 0.5
        platformPart.BrickColor = BrickColor.new("Cyan")
        platformPart.Parent = Workspace
    end)
    if not success then
        platformPart = nil
    end
end

--// ============================================================
--// ANTI-AFK
--// ============================================================

local function startAntiAFK()
    if antiAFKConn then return end
    antiAFKConn = LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end

--// ============================================================
--// NO FALL DAMAGE
--// ============================================================

local function toggleNoFallDMG(enable)
    if enable then
        if noFallConn then noFallConn:Disconnect() end
        noFallConn = RunService.Heartbeat:Connect(function()
            local hum = getHumanoid()
            if hum and hum.Health < hum.MaxHealth then
                hum.Health = hum.MaxHealth
            end
        end)
        isNoFallDmg = true
    else
        if noFallConn then
            noFallConn:Disconnect()
            noFallConn = nil
        end
        isNoFallDmg = false
    end
end

--// ============================================================
--// NOCLIP (IY-style)
--// ============================================================

local function toggleNoclip(enable)
    if enable then
        if noclipConn then noclipConn:Disconnect() end
        noclipConn = RunService.Stepped:Connect(function()
            local char = getCharacter()
            if char then
                for _, part in ipairs(char:GetDescendants()) do
                    if part:IsA("BasePart") then
                        part.CanCollide = false
                    end
                end
            end
        end)
        isNoclipping = true
    else
        if noclipConn then
            noclipConn:Disconnect()
            noclipConn = nil
        end
        -- Restore collisions
        local char = getCharacter()
        if char then
            for _, part in ipairs(char:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = true
                end
            end
        end
        isNoclipping = false
    end
end

--// ============================================================
--// FLY (Infinite Yield style - BodyGyro/BodyVelocity + CFrame fallback)
--// ============================================================

local function startFly()
    if isFlying then return end
    local hrp = getHRP()
    if not hrp then return end

    isFlying = true

    local success = false

    -- Try BodyGyro + BodyVelocity (IY-style)
    local ok, _ = pcall(function()
        flyBodyVelocity = Instance.new("BodyVelocity")
        flyBodyVelocity.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
        flyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
        flyBodyVelocity.P = 10000
        flyBodyVelocity.Parent = hrp

        flyBodyGyro = Instance.new("BodyGyro")
        flyBodyGyro.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
        flyBodyGyro.P = 15000
        flyBodyGyro.D = 1000
        flyBodyGyro.Parent = hrp

        success = true
    end)

    if not success then
        -- CFrame fallback
        flyBodyVelocity = nil
        flyBodyGyro = nil
    end

    local camera = Workspace.CurrentCamera

    flyConn = RunService.Heartbeat:Connect(function(dt)
        if not isFlying then return end
        local char = getCharacter()
        if not char then return end
        local hr = char:FindFirstChild("HumanoidRootPart")
        if not hr then return end

        local camCF = camera.CFrame
        local direction = Vector3.new(0, 0, 0)

        if UserInputService:IsKeyDown(Enum.KeyCode.W) then
            direction = direction + camCF.LookVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then
            direction = direction - camCF.LookVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then
            direction = direction - camCF.RightVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then
            direction = direction + camCF.RightVector
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            direction = direction + Vector3.new(0, 1, 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
            direction = direction - Vector3.new(0, 1, 0)
        end

        if direction.Magnitude > 0 then
            direction = direction.Unit * flySpeed
        end

        if flyBodyVelocity and flyBodyVelocity.Parent then
            flyBodyVelocity.Velocity = direction
            if flyBodyGyro and flyBodyGyro.Parent then
                flyBodyGyro.CFrame = camCF
            end
        else
            -- CFrame fallback
            hr.CFrame = hr.CFrame + (direction * dt)
        end
    end)
end

local function stopFly()
    isFlying = false
    if flyConn then
        flyConn:Disconnect()
        flyConn = nil
    end
    if flyBodyVelocity then
        flyBodyVelocity:Destroy()
        flyBodyVelocity = nil
    end
    if flyBodyGyro then
        flyBodyGyro:Destroy()
        flyBodyGyro = nil
    end
end

local function toggleFly()
    if isFlying then
        stopFly()
    else
        startFly()
    end
end

--// ============================================================
--// MINING / FARMING
--// ============================================================

local function mineRock(rock)
    local toolEvent = getToolEvent()
    if not toolEvent then return false end

    local char = getCharacter()
    if not char then return false end

    -- Find pickaxe in Character or Backpack
    local pickaxe = nil
    for _, item in ipairs(char:GetChildren()) do
        if item:IsA("Tool") or item.Name:lower():find("pickaxe") or item.Name:lower():find("pick") then
            pickaxe = item
            break
        end
    end
    if not pickaxe then
        local backpack = LocalPlayer:FindFirstChild("Backpack")
        if backpack then
            for _, item in ipairs(backpack:GetChildren()) do
                if item:IsA("Tool") or item.Name:lower():find("pickaxe") or item.Name:lower():find("pick") then
                    pickaxe = item
                    break
                end
            end
        end
    end

    -- Fire double MineOres remote (game sends 2 per hit)
    pcall(function()
        -- First: pickaxe in Character
        if pickaxe then
            toolEvent:FireServer("MineOres", pickaxe, rock)
        else
            toolEvent:FireServer("MineOres", rock)
        end
        -- Second: pickaxe Parented to nil (animation state)
        if pickaxe then
            local oldParent = pickaxe.Parent
            pickaxe.Parent = nil
            toolEvent:FireServer("MineOres", pickaxe, rock)
            pickaxe.Parent = oldParent
        end
    end)

    return true
end

local function sellOre()
    local sellRemote = getSellRemote()
    if not sellRemote then return false end

    local inventory = countInventoryItems()
    local sold = false

    for oreName, count in pairs(inventory) do
        if count > 0 and ORE_PRICES[oreName] then
            pcall(function()
                sellRemote:FireServer(oreName, count)
            end)
            sold = true
        end
    end

    return sold
end

local function teleportTo(position)
    local hrp = getHRP()
    if hrp then
        hrp.CFrame = CFrame.new(position)
    end
end

local function sellAllOre()
    local buyer = getMineralBuyer()
    if not buyer then return end

    -- Get earnings before selling
    local inventory = countInventoryItems()
    local earningsBefore = calculateEarnings(inventory)

    -- TP to buyer
    local buyerPos = buyer:FindFirstChild("HumanoidRootPart") and buyer.HumanoidRootPart.Position or buyer.PrimaryPart and buyer.PrimaryPart.Position or buyer.Position
    if buyerPos then
        teleportTo(buyerPos + Vector3.new(0, 0, 3))
        wait(0.3)
    end

    -- Sell
    sellOre()
    wait(0.5)

    -- Return to cave
    teleportTo(CAVE_POS)
    wait(0.3)
end

--// ============================================================
--// MAIN FARM LOOP
--// ============================================================

local farmThread = nil

local function farmLoop()
    while isFarming do
        -- Find nearest rock (skip already mined ones)
        local rock, dist = findNearestRock(minedRocks)

        if not rock then
            -- All rocks mined, reset cache and wait
            minedRocks = {}
            wait(2)
            continue
        end

        if not isRockValid(rock) then
            table.insert(minedRocks, rock)
            continue
        end

        -- TP to cave first time or after sell
        local hrp = getHRP()
        if not hrp then
            wait(1)
            continue
        end

        -- Check distance to cave - if far, TP to cave first
        local distToCave = (hrp.Position - CAVE_POS).Magnitude
        if distToCave > 200 then
            teleportTo(CAVE_POS)
            wait(0.5)
        end

        -- Position: stand 5 studs from rock, looking at it
        local rockPos = rock.Position
        local direction = (hrp.Position - rockPos).Unit
        local standPos = rockPos + (direction * MINING_DISTANCE)
        standPos = Vector3.new(standPos.X, rockPos.Y + 3, standPos.Z)

        teleportTo(standPos)
        wait(0.3)

        -- Create platform under player
        createPlatform(hrp.Position)

        -- Look at rock
        hrp.CFrame = CFrame.new(hrp.Position, rockPos)

        -- Disable noclip for mining
        if isNoclipping then
            toggleNoclip(false)
        end

        -- Mine the rock
        local hitCount = 0
        local maxHits = 60 -- Safety timeout (15 seconds at 0.45 interval)

        while isFarming and isRockValid(rock) and hitCount < maxHits do
            -- Check if rock still exists
            if rock.Parent == nil or not Workspace:IsAncestorOf(rock) then
                break
            end

            -- Track inventory before hit
            local invBefore = countInventoryItems()
            local oreBefore = getTotalOreCount(invBefore)

            -- Mine
            mineRock(rock)
            hitCount = hitCount + 1

            wait(HIT_INTERVAL)

            -- Check if ore appeared in inventory (rock broken)
            local invAfter = countInventoryItems()
            local oreAfter = getTotalOreCount(invAfter)

            if oreAfter > oreBefore then
                -- Rock broken!
                totalOreMined = totalOreMined + (oreAfter - oreBefore)
                currentSessionOre = currentSessionOre + (oreAfter - oreBefore)
                break
            end
        end

        -- Mark rock as mined
        table.insert(minedRocks, rock)
        lastRockPosition = rock.Position

        -- Remove platform
        removePlatform()

        -- Check if we should sell
        local currentInv = countInventoryItems()
        local totalOre = getTotalOreCount(currentInv)

        if totalOre >= 20 then
            -- Sell ore
            local earnings = calculateEarnings(currentInv)
            totalEarnings = totalEarnings + earnings
            currentSessionEarnings = currentSessionEarnings + earnings
            sellAllOre()
        end

        -- Update platform position for next rock
        wait(0.1)
    end

    -- Clean up
    removePlatform()
end

local function startFarming()
    if isFarming then return end
    isFarming = true
    farmStartTime = tick()
    frozenTimeStr = "00:00:00"
    frozenOreCount = 0
    frozenEarnings = 0
    currentSessionOre = 0
    currentSessionEarnings = 0
    minedRocks = {}

    -- TP to cave
    teleportTo(CAVE_POS)
    wait(0.5)

    -- Start farm in new thread
    farmThread = coroutine.wrap(farmLoop)
    farmThread()
end

local function stopFarming()
    isFarming = false
    removePlatform()

    -- Freeze timer values
    if farmStartTime > 0 then
        frozenTimeStr = formatTime(tick() - farmStartTime)
    end
    frozenOreCount = currentSessionOre
    frozenEarnings = currentSessionEarnings

    -- Re-enable noclip if it was on
    -- (it's toggled off during mining, user can re-enable)
end

--// ============================================================
--// UI - TAB SYSTEM
--// ============================================================

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "AIScript"
ScreenGui.ResetOnSpawn = false
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = game:GetService("CoreGui")

--// Main Frame
local MainFrame = Instance.new("Frame")
MainFrame.Name = "MainFrame"
MainFrame.Size = UDim2.new(0, 380, 0, 520)
MainFrame.Position = UDim2.new(0.5, -190, 0.5, -260)
MainFrame.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
MainFrame.BorderSizePixel = 0
MainFrame.Active = true
MainFrame.Draggable = true
MainFrame.Parent = ScreenGui

local MainCorner = Instance.new("UICorner")
MainCorner.CornerRadius = UDim.new(0, 12)
MainCorner.Parent = MainFrame

local MainStroke = Instance.new("UIStroke")
MainStroke.Color = Color3.fromRGB(60, 60, 80)
MainStroke.Thickness = 1.5
MainStroke.Parent = MainFrame

--// Title Bar
local TitleBar = Instance.new("Frame")
TitleBar.Name = "TitleBar"
TitleBar.Size = UDim2.new(1, 0, 0, 40)
TitleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
TitleBar.BorderSizePixel = 0
TitleBar.Parent = MainFrame

local TitleCorner = Instance.new("UICorner")
TitleCorner.CornerRadius = UDim.new(0, 12)
TitleCorner.Parent = TitleBar

local TitleLabel = Instance.new("TextLabel")
TitleLabel.Text = "AI SCRIPT v0.01"
TitleLabel.Size = UDim2.new(1, -40, 1, 0)
TitleLabel.Position = UDim2.new(0, 15, 0, 0)
TitleLabel.BackgroundTransparency = 1
TitleLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
TitleLabel.TextSize = 16
TitleLabel.Font = Enum.Font.GothamBold
TitleLabel.TextXAlignment = Enum.TextXAlignment.Left
TitleLabel.Parent = TitleBar

-- Close Button
local CloseBtn = Instance.new("TextButton")
CloseBtn.Text = "X"
CloseBtn.Size = UDim2.new(0, 30, 0, 30)
CloseBtn.Position = UDim2.new(1, -35, 0, 5)
CloseBtn.BackgroundColor3 = Color3.fromRGB(200, 50, 50)
CloseBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
CloseBtn.Font = Enum.Font.GothamBold
CloseBtn.TextSize = 14
CloseBtn.BorderSizePixel = 0
CloseBtn.Parent = TitleBar

local CloseCorner = Instance.new("UICorner")
CloseCorner.CornerRadius = UDim.new(0, 6)
CloseCorner.Parent = CloseBtn

CloseBtn.MouseButton1Click:Connect(function()
    ScreenGui:Destroy()
    stopFly()
    toggleNoclip(false)
    toggleNoFallDMG(false)
    isFarming = false
    removePlatform()
end)

--// Minimize Button
local MinBtn = Instance.new("TextButton")
MinBtn.Text = "-"
MinBtn.Size = UDim2.new(0, 30, 0, 30)
MinBtn.Position = UDim2.new(1, -70, 0, 5)
MinBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
MinBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
MinBtn.Font = Enum.Font.GothamBold
MinBtn.TextSize = 14
MinBtn.BorderSizePixel = 0
MinBtn.Parent = TitleBar

local MinCorner = Instance.new("UICorner")
MinCorner.CornerRadius = UDim.new(0, 6)
MinCorner.Parent = MinBtn

--// Content Area (where pages swap)
local ContentArea = Instance.new("Frame")
ContentArea.Name = "ContentArea"
ContentArea.Size = UDim2.new(1, -20, 1, -50)
ContentArea.Position = UDim2.new(0, 10, 0, 45)
ContentArea.BackgroundTransparency = 1
ContentArea.Parent = MainFrame

--// ============================================================
--// PAGE: HOME (Tab Selector)
--// ============================================================

local HomePage = Instance.new("Frame")
HomePage.Name = "HomePage"
HomePage.Size = UDim2.new(1, 0, 1, 0)
HomePage.BackgroundTransparency = 1
HomePage.Parent = ContentArea

local HomeTitle = Instance.new("TextLabel")
HomeTitle.Text = "Select Feature"
HomeTitle.Size = UDim2.new(1, 0, 0, 30)
HomeTitle.BackgroundTransparency = 1
HomeTitle.TextColor3 = Color3.fromRGB(160, 160, 200)
HomeTitle.Font = Enum.Font.Gotham
HomeTitle.TextSize = 13
HomeTitle.Parent = HomePage

-- Tab Buttons Container
local TabsContainer = Instance.new("Frame")
TabsContainer.Name = "TabsContainer"
TabsContainer.Size = UDim2.new(1, 0, 1, -40)
TabsContainer.Position = UDim2.new(0, 0, 0, 35)
TabsContainer.BackgroundTransparency = 1
TabsContainer.Parent = HomePage

local TabsLayout = Instance.new("UIListLayout")
TabsLayout.Padding = UDim.new(0, 8)
TabsLayout.SortOrder = Enum.SortOrder.LayoutOrder
TabsLayout.Parent = TabsContainer

-- Helper: Create Tab Button
local function createTabButton(name, emoji, order)
    local btn = Instance.new("TextButton")
    btn.Name = name .. "Tab"
    btn.Size = UDim2.new(1, 0, 0, 55)
    btn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
    btn.BorderSizePixel = 0
    btn.Text = emoji .. "  " .. name
    btn.TextColor3 = Color3.fromRGB(220, 220, 255)
    btn.Font = Enum.Font.GothamBold
    btn.TextSize = 16
    btn.LayoutOrder = order
    btn.Parent = TabsContainer

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = btn

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(60, 60, 90)
    stroke.Thickness = 1
    stroke.Parent = btn

    btn.MouseEnter:Connect(function()
        btn.BackgroundColor3 = Color3.fromRGB(50, 50, 75)
    end)
    btn.MouseLeave:Connect(function()
        btn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
    end)

    return btn
end

-- Create tab buttons
local oreFarmTab = createTabButton("ORE FARM", "\xe2\x9b\x8f\xef\xb8\x8f", 1) -- ⛏️
local flyTab = createTabButton("MOVEMENT", "\xf0\x9f\x9a\x80", 2) -- 🚀
local miscTab = createTabButton("MISC", "\xe2\x9a\x99\xef\xb8\x8f", 3) -- ⚙️

--// ============================================================
--// BACK BUTTON (shared component for sub-pages)
--// ============================================================

local function createBackButton(parent)
    local backBtn = Instance.new("TextButton")
    backBtn.Name = "BackBtn"
    backBtn.Size = UDim2.new(0, 80, 0, 28)
    backBtn.Position = UDim2.new(0, 0, 0, 0)
    backBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
    backBtn.BorderSizePixel = 0
    backBtn.Text = "\xe2\xac\x85\xef\xb8\x8f BACK" -- ⬅️ BACK
    backBtn.TextColor3 = Color3.fromRGB(180, 180, 220)
    backBtn.Font = Enum.Font.GothamBold
    backBtn.TextSize = 11
    backBtn.Parent = parent

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = backBtn

    return backBtn
end

--// ============================================================
--// PAGE: ORE FARM
--// ============================================================

local OreFarmPage = Instance.new("Frame")
OreFarmPage.Name = "OreFarmPage"
OreFarmPage.Size = UDim2.new(1, 0, 1, 0)
OreFarmPage.BackgroundTransparency = 1
OreFarmPage.Visible = false
OreFarmPage.Parent = ContentArea

local oreBackBtn = createBackButton(OreFarmPage)

local orePageLayout = Instance.new("UIListLayout")
orePageLayout.Padding = UDim.new(0, 6)
orePageLayout.SortOrder = Enum.SortOrder.LayoutOrder
orePageLayout.Parent = OreFarmPage

-- Title
local oreTitle = Instance.new("TextLabel")
oreTitle.Text = "\xe2\x9b\x8f\xef\xb8\x8f ORE FARM" -- ⛏️ ORE FARM
oreTitle.Size = UDim2.new(1, 0, 0, 30)
oreTitle.BackgroundTransparency = 1
oreTitle.TextColor3 = Color3.fromRGB(100, 200, 255)
oreTitle.Font = Enum.Font.GothamBold
oreTitle.TextSize = 18
oreTitle.LayoutOrder = 1
oreTitle.Parent = OreFarmPage

-- Start/Stop Farm Button
local FarmBtn = Instance.new("TextButton")
FarmBtn.Name = "FarmBtn"
FarmBtn.Size = UDim2.new(1, 0, 0, 40)
FarmBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 40)
FarmBtn.BorderSizePixel = 0
FarmBtn.Text = "\xe2\x9b\x8f\xef\xb8\x8f START FARM" -- ⛏️ START FARM
FarmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
FarmBtn.Font = Enum.Font.GothamBold
FarmBtn.TextSize = 15
FarmBtn.LayoutOrder = 2
FarmBtn.Parent = OreFarmPage

local FarmBtnCorner = Instance.new("UICorner")
FarmBtnCorner.CornerRadius = UDim.new(0, 8)
FarmBtnCorner.Parent = FarmBtn

-- Stats Frame
local StatsFrame = Instance.new("Frame")
StatsFrame.Size = UDim2.new(1, 0, 0, 115)
StatsFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
StatsFrame.BorderSizePixel = 0
StatsFrame.LayoutOrder = 3
StatsFrame.Parent = OreFarmPage

local StatsCorner = Instance.new("UICorner")
StatsCorner.CornerRadius = UDim.new(0, 8)
StatsCorner.Parent = StatsFrame

local StatsLayout = Instance.new("UIListLayout")
StatsLayout.Padding = UDim.new(0, 2)
StatsLayout.Parent = StatsFrame

local StatsPadding = Instance.new("UIPadding")
StatsPadding.PaddingTop = UDim.new(0, 6)
StatsPadding.PaddingLeft = UDim.new(0, 10)
StatsPadding.Parent = StatsFrame

-- Time Label
local TimeLabel = Instance.new("TextLabel")
TimeLabel.Text = "\xe2\x8f\xb1\xef\xb8\x8f Time: 00:00:00" -- ⏱️ Time
TimeLabel.Size = UDim2.new(1, -20, 0, 22)
TimeLabel.BackgroundTransparency = 1
TimeLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
TimeLabel.Font = Enum.Font.Gotham
TimeLabel.TextSize = 13
TimeLabel.TextXAlignment = Enum.TextXAlignment.Left
TimeLabel.Parent = StatsFrame

-- Ore Count Label
local OreLabel = Instance.new("TextLabel")
OreLabel.Text = "\xf0\x9f\xaa\xa8 Ore Mined: 0" -- 🪨 Ore
OreLabel.Size = UDim2.new(1, -20, 0, 22)
OreLabel.BackgroundTransparency = 1
OreLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
OreLabel.Font = Enum.Font.Gotham
OreLabel.TextSize = 13
OreLabel.TextXAlignment = Enum.TextXAlignment.Left
OreLabel.Parent = StatsFrame

-- Earnings Label
local EarnLabel = Instance.new("TextLabel")
EarnLabel.Text = "\xf0\x9f\x92\xb0 Earnings: $0" -- 💰 Earnings
EarnLabel.Size = UDim2.new(1, -20, 0, 22)
EarnLabel.BackgroundTransparency = 1
EarnLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
EarnLabel.Font = Enum.Font.Gotham
EarnLabel.TextSize = 13
EarnLabel.TextXAlignment = Enum.TextXAlignment.Left
EarnLabel.Parent = StatsFrame

-- Inventory Label
local InvLabel = Instance.new("TextLabel")
InvLabel.Text = "\xf0\x9f\x8e\x92 Inventory: 0 ore ($0)" -- 🎒 Inventory
InvLabel.Size = UDim2.new(1, -20, 0, 22)
InvLabel.BackgroundTransparency = 1
InvLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
InvLabel.Font = Enum.Font.Gotham
InvLabel.TextSize = 13
InvLabel.TextXAlignment = Enum.TextXAlignment.Left
InvLabel.Parent = StatsFrame

-- Status Label
local StatusLabel = Instance.new("TextLabel")
StatusLabel.Text = "\xf0\x9f\x9f\xa2 Status: Idle" -- 🟢 Status
StatusLabel.Size = UDim2.new(1, 0, 0, 22)
StatusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
StatusLabel.BorderSizePixel = 0
StatusLabel.TextColor3 = Color3.fromRGB(100, 200, 100)
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextSize = 12
StatusLabel.LayoutOrder = 4
StatusLabel.Parent = OreFarmPage

-- Sell Button
local SellBtn = Instance.new("TextButton")
SellBtn.Size = UDim2.new(1, 0, 0, 35)
SellBtn.BackgroundColor3 = Color3.fromRGB(180, 120, 20)
SellBtn.BorderSizePixel = 0
SellBtn.Text = "\xf0\x9f\x92\xb0 SELL ALL ORE" -- 💰 SELL
SellBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
SellBtn.Font = Enum.Font.GothamBold
SellBtn.TextSize = 14
SellBtn.LayoutOrder = 5
SellBtn.Parent = OreFarmPage

local SellBtnCorner = Instance.new("UICorner")
SellBtnCorner.CornerRadius = UDim.new(0, 8)
SellBtnCorner.Parent = SellBtn

-- Platform Toggle
local PlatformBtn = Instance.new("TextButton")
PlatformBtn.Size = UDim2.new(1, 0, 0, 32)
PlatformBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
PlatformBtn.BorderSizePixel = 0
PlatformBtn.Text = "\xf0\x9f\x9f\xa9 Platform: AUTO" -- 🟩 Platform
PlatformBtn.TextColor3 = Color3.fromRGB(200, 200, 255)
PlatformBtn.Font = Enum.Font.GothamBold
PlatformBtn.TextSize = 12
PlatformBtn.LayoutOrder = 6
PlatformBtn.Parent = OreFarmPage

local PlatBtnCorner = Instance.new("UICorner")
PlatBtnCorner.CornerRadius = UDim.new(0, 6)
PlatBtnCorner.Parent = PlatformBtn

--// ============================================================
--// PAGE: MOVEMENT (Fly + Noclip)
--// ============================================================

local MovementPage = Instance.new("Frame")
MovementPage.Name = "MovementPage"
MovementPage.Size = UDim2.new(1, 0, 1, 0)
MovementPage.BackgroundTransparency = 1
MovementPage.Visible = false
MovementPage.Parent = ContentArea

local moveBackBtn = createBackButton(MovementPage)

local movePageLayout = Instance.new("UIListLayout")
movePageLayout.Padding = UDim.new(0, 8)
movePageLayout.SortOrder = Enum.SortOrder.LayoutOrder
movePageLayout.Parent = MovementPage

local moveTitle = Instance.new("TextLabel")
moveTitle.Text = "\xf0\x9f\x9a\x80 MOVEMENT" -- 🚀 MOVEMENT
moveTitle.Size = UDim2.new(1, 0, 0, 30)
moveTitle.BackgroundTransparency = 1
moveTitle.TextColor3 = Color3.fromRGB(100, 200, 255)
moveTitle.Font = Enum.Font.GothamBold
moveTitle.TextSize = 18
moveTitle.LayoutOrder = 1
moveTitle.Parent = MovementPage

-- Fly Button
local FlyBtn = Instance.new("TextButton")
FlyBtn.Size = UDim2.new(1, 0, 0, 40)
FlyBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 160)
FlyBtn.BorderSizePixel = 0
FlyBtn.Text = "\xf0\x9f\x90\xa4 FLY: OFF" -- 🐤 FLY
FlyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
FlyBtn.Font = Enum.Font.GothamBold
FlyBtn.TextSize = 15
FlyBtn.LayoutOrder = 2
FlyBtn.Parent = MovementPage

local FlyBtnCorner = Instance.new("UICorner")
FlyBtnCorner.CornerRadius = UDim.new(0, 8)
FlyBtnCorner.Parent = FlyBtn

-- Fly Speed
local SpeedFrame = Instance.new("Frame")
SpeedFrame.Size = UDim2.new(1, 0, 0, 35)
SpeedFrame.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
SpeedFrame.BorderSizePixel = 0
SpeedFrame.LayoutOrder = 3
SpeedFrame.Parent = MovementPage

local SpeedCorner = Instance.new("UICorner")
SpeedCorner.CornerRadius = UDim.new(0, 6)
SpeedCorner.Parent = SpeedFrame

local SpeedLabel = Instance.new("TextLabel")
SpeedLabel.Text = "\xf0\x9f\x92\xa8 Speed: 80" -- 💨 Speed
SpeedLabel.Size = UDim2.new(0.5, 0, 1, 0)
SpeedLabel.BackgroundTransparency = 1
SpeedLabel.TextColor3 = Color3.fromRGB(180, 180, 220)
SpeedLabel.Font = Enum.Font.Gotham
SpeedLabel.TextSize = 13
SpeedLabel.Parent = SpeedFrame

local SpeedDown = Instance.new("TextButton")
SpeedDown.Size = UDim2.new(0, 40, 0, 25)
SpeedDown.Position = UDim2.new(0.5, 5, 0.5, -12)
SpeedDown.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
SpeedDown.Text = "-"
SpeedDown.TextColor3 = Color3.fromRGB(255, 255, 255)
SpeedDown.Font = Enum.Font.GothamBold
SpeedDown.TextSize = 16
SpeedDown.BorderSizePixel = 0
SpeedDown.Parent = SpeedFrame

local SpeedDownCorner = Instance.new("UICorner")
SpeedDownCorner.CornerRadius = UDim.new(0, 4)
SpeedDownCorner.Parent = SpeedDown

local SpeedUp = Instance.new("TextButton")
SpeedUp.Size = UDim2.new(0, 40, 0, 25)
SpeedUp.Position = UDim2.new(1, -45, 0.5, -12)
SpeedUp.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
SpeedUp.Text = "+"
SpeedUp.TextColor3 = Color3.fromRGB(255, 255, 255)
SpeedUp.Font = Enum.Font.GothamBold
SpeedUp.TextSize = 16
SpeedUp.BorderSizePixel = 0
SpeedUp.Parent = SpeedFrame

local SpeedUpCorner = Instance.new("UICorner")
SpeedUpCorner.CornerRadius = UDim.new(0, 4)
SpeedUpCorner.Parent = SpeedUp

-- Noclip Button
local NoclipBtn = Instance.new("TextButton")
NoclipBtn.Size = UDim2.new(1, 0, 0, 40)
NoclipBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
NoclipBtn.BorderSizePixel = 0
NoclipBtn.Text = "\xf0\x9f\x91\xbb NOCLIP: OFF" -- 👻 NOCLIP
NoclipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
NoclipBtn.Font = Enum.Font.GothamBold
NoclipBtn.TextSize = 15
NoclipBtn.LayoutOrder = 4
NoclipBtn.Parent = MovementPage

local NoclipBtnCorner = Instance.new("UICorner")
NoclipBtnCorner.CornerRadius = UDim.new(0, 8)
NoclipBtnCorner.Parent = NoclipBtn

-- Fly Keybind Hint
local FlyHint = Instance.new("TextLabel")
FlyHint.Text = "WASD + Space/Shift to fly | V to toggle fly"
FlyHint.Size = UDim2.new(1, 0, 0, 20)
FlyHint.BackgroundTransparency = 1
FlyHint.TextColor3 = Color3.fromRGB(100, 100, 140)
FlyHint.Font = Enum.Font.Gotham
FlyHint.TextSize = 11
FlyHint.LayoutOrder = 5
FlyHint.Parent = MovementPage

--// ============================================================
--// PAGE: MISC (No Fall DMG, Anti-AFK, etc.)
--// ============================================================

local MiscPage = Instance.new("Frame")
MiscPage.Name = "MiscPage"
MiscPage.Size = UDim2.new(1, 0, 1, 0)
MiscPage.BackgroundTransparency = 1
MiscPage.Visible = false
MiscPage.Parent = ContentArea

local miscBackBtn = createBackButton(MiscPage)

local miscPageLayout = Instance.new("UIListLayout")
miscPageLayout.Padding = UDim.new(0, 8)
miscPageLayout.SortOrder = Enum.SortOrder.LayoutOrder
miscPageLayout.Parent = MiscPage

local miscTitle = Instance.new("TextLabel")
miscTitle.Text = "\xe2\x9a\x99\xef\xb8\x8f MISC" -- ⚙️ MISC
miscTitle.Size = UDim2.new(1, 0, 0, 30)
miscTitle.BackgroundTransparency = 1
miscTitle.TextColor3 = Color3.fromRGB(100, 200, 255)
miscTitle.Font = Enum.Font.GothamBold
miscTitle.TextSize = 18
miscTitle.LayoutOrder = 1
miscTitle.Parent = MiscPage

-- No Fall DMG Button
local NoFallBtn = Instance.new("TextButton")
NoFallBtn.Size = UDim2.new(1, 0, 0, 40)
NoFallBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
NoFallBtn.BorderSizePixel = 0
NoFallBtn.Text = "\xf0\x9f\x9b\xa1\xef\xb8\x8f NO FALL DMG: OFF" -- 🛡️ NO FALL DMG
NoFallBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
NoFallBtn.Font = Enum.Font.GothamBold
NoFallBtn.TextSize = 15
NoFallBtn.LayoutOrder = 2
NoFallBtn.Parent = MiscPage

local NoFallBtnCorner = Instance.new("UICorner")
NoFallBtnCorner.CornerRadius = UDim.new(0, 8)
NoFallBtnCorner.Parent = NoFallBtn

-- Anti-AFK Button
local AntiAFKBtn = Instance.new("TextButton")
AntiAFKBtn.Size = UDim2.new(1, 0, 0, 40)
AntiAFKBtn.BackgroundColor3 = Color3.fromRGB(35, 120, 35)
AntiAFKBtn.BorderSizePixel = 0
AntiAFKBtn.Text = "\xe2\x98\x95 ANTI-AFK: ON" -- ☕ ANTI-AFK
AntiAFKBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
AntiAFKBtn.Font = Enum.Font.GothamBold
AntiAFKBtn.TextSize = 15
AntiAFKBtn.LayoutOrder = 3
AntiAFKBtn.Parent = MiscPage

local AntiAFKBtnCorner = Instance.new("UICorner")
AntiAFKBtnCorner.CornerRadius = UDim.new(0, 8)
AntiAFKBtnCorner.Parent = AntiAFKBtn

--// ============================================================
--// PAGE NAVIGATION
--// ============================================================

local function showPage(pageName)
    for _, page in ipairs(ContentArea:GetChildren()) do
        if page:IsA("Frame") and page.Name:find("Page") then
            page.Visible = (page.Name == pageName)
        end
    end
end

-- Tab button clicks
oreFarmTab.MouseButton1Click:Connect(function()
    showPage("OreFarmPage")
end)

flyTab.MouseButton1Click:Connect(function()
    showPage("MovementPage")
end)

miscTab.MouseButton1Click:Connect(function()
    showPage("MiscPage")
end)

-- Back button clicks
oreBackBtn.MouseButton1Click:Connect(function()
    showPage("HomePage")
end)

moveBackBtn.MouseButton1Click:Connect(function()
    showPage("HomePage")
end)

miscBackBtn.MouseButton1Click:Connect(function()
    showPage("HomePage")
end)

-- Start on Home page
showPage("HomePage")

--// ============================================================
--// BUTTON LOGIC
--// ============================================================

-- Farm Button
FarmBtn.MouseButton1Click:Connect(function()
    if isFarming then
        stopFarming()
        FarmBtn.Text = "\xe2\x9b\x8f\xef\xb8\x8f START FARM" -- ⛏️ START FARM
        FarmBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 40)
        StatusLabel.Text = "\xf0\x9f\x9f\xa1 Status: Stopped" -- 🟡
        StatusLabel.TextColor3 = Color3.fromRGB(200, 200, 50)
    else
        startFarming()
        FarmBtn.Text = "\xe2\x9b\x8f\xef\xb8\x8f STOP FARM" -- ⛏️ STOP FARM
        FarmBtn.BackgroundColor3 = Color3.fromRGB(160, 40, 40)
        StatusLabel.Text = "\xf0\x9f\x9f\xa2 Status: Farming..." -- 🟢
        StatusLabel.TextColor3 = Color3.fromRGB(100, 200, 100)
    end
end)

-- Sell Button
SellBtn.MouseButton1Click:Connect(function()
    if not isFarming then
        local inv = countInventoryItems()
        local earnings = calculateEarnings(inv)
        if getTotalOreCount(inv) > 0 then
            totalEarnings = totalEarnings + earnings
            currentSessionEarnings = currentSessionEarnings + earnings
            sellAllOre()
            StatusLabel.Text = "\xf0\x9f\x92\xb0 Sold ore!" -- 💰
            StatusLabel.TextColor3 = Color3.fromRGB(255, 200, 50)
            wait(1)
            StatusLabel.Text = "\xf0\x9f\x9f\xa2 Status: Idle" -- 🟢
        end
    end
end)

-- Platform Toggle
local platformMode = 0 -- 0=AUTO, 1=ON, 2=OFF
PlatformBtn.MouseButton1Click:Connect(function()
    platformMode = (platformMode + 1) % 3
    if platformMode == 0 then
        PlatformBtn.Text = "\xf0\x9f\x9f\xa9 Platform: AUTO" -- 🟩
    elseif platformMode == 1 then
        PlatformBtn.Text = "\xf0\x9f\x9f\xa9 Platform: ON" -- 🟩
        -- Force platform on
        local hrp = getHRP()
        if hrp then createPlatform(hrp.Position) end
    else
        PlatformBtn.Text = "\xf0\x9f\x94\xb4 Platform: OFF" -- 🔴
        removePlatform()
    end
end)

-- Fly Button
FlyBtn.MouseButton1Click:Connect(function()
    toggleFly()
    if isFlying then
        FlyBtn.Text = "\xf0\x9f\x90\xa4 FLY: ON" -- 🐤 FLY ON
        FlyBtn.BackgroundColor3 = Color3.fromRGB(20, 120, 200)
    else
        FlyBtn.Text = "\xf0\x9f\x90\xa4 FLY: OFF" -- 🐤 FLY OFF
        FlyBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 160)
    end
end)

-- Fly Speed
SpeedDown.MouseButton1Click:Connect(function()
    flySpeed = math.max(10, flySpeed - 10)
    SpeedLabel.Text = "\xf0\x9f\x92\xa8 Speed: " .. flySpeed -- 💨
end)

SpeedUp.MouseButton1Click:Connect(function()
    flySpeed = math.min(300, flySpeed + 10)
    SpeedLabel.Text = "\xf0\x9f\x92\xa8 Speed: " .. flySpeed -- 💨
end)

-- Noclip Button
NoclipBtn.MouseButton1Click:Connect(function()
    toggleNoclip(not isNoclipping)
    if isNoclipping then
        NoclipBtn.Text = "\xf0\x9f\x91\xbb NOCLIP: ON" -- 👻 ON
        NoclipBtn.BackgroundColor3 = Color3.fromRGB(120, 40, 120)
    else
        NoclipBtn.Text = "\xf0\x9f\x91\xbb NOCLIP: OFF" -- 👻 OFF
        NoclipBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
    end
end)

-- No Fall DMG Button
NoFallBtn.MouseButton1Click:Connect(function()
    toggleNoFallDMG(not isNoFallDmg)
    if isNoFallDmg then
        NoFallBtn.Text = "\xf0\x9f\x9b\xa1\xef\xb8\x8f NO FALL DMG: ON" -- 🛡️ ON
        NoFallBtn.BackgroundColor3 = Color3.fromRGB(20, 120, 60)
    else
        NoFallBtn.Text = "\xf0\x9f\x9b\xa1\xef\xb8\x8f NO FALL DMG: OFF" -- 🛡️ OFF
        NoFallBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
    end
end)

-- Anti-AFK Button (starts ON)
startAntiAFK()
AntiAFKBtn.MouseButton1Click:Connect(function()
    if antiAFKConn then
        antiAFKConn:Disconnect()
        antiAFKConn = nil
        AntiAFKBtn.Text = "\xe2\x98\x95 ANTI-AFK: OFF" -- ☕ OFF
        AntiAFKBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 50)
    else
        startAntiAFK()
        AntiAFKBtn.Text = "\xe2\x98\x95 ANTI-AFK: ON" -- ☕ ON
        AntiAFKBtn.BackgroundColor3 = Color3.fromRGB(35, 120, 35)
    end
end)

--// Minimize Toggle
local isMinimized = false
MinBtn.MouseButton1Click:Connect(function()
    isMinimized = not isMinimized
    ContentArea.Visible = not isMinimized
    if isMinimized then
        MainFrame.Size = UDim2.new(0, 380, 0, 40)
    else
        MainFrame.Size = UDim2.new(0, 380, 0, 520)
    end
end)

--// V key to toggle fly
UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if gameProcessed then return end
    if input.KeyCode == Enum.KeyCode.V then
        toggleFly()
        if isFlying then
            FlyBtn.Text = "\xf0\x9f\x90\xa4 FLY: ON" -- 🐤 ON
            FlyBtn.BackgroundColor3 = Color3.fromRGB(20, 120, 200)
        else
            FlyBtn.Text = "\xf0\x9f\x90\xa4 FLY: OFF" -- 🐤 OFF
            FlyBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 160)
        end
    end
end)

--// ============================================================
--// STATS UPDATE LOOP
--// ============================================================

RunService.Heartbeat:Connect(function()
    if isFarming then
        local elapsed = tick() - farmStartTime
        TimeLabel.Text = "\xe2\x8f\xb1\xef\xb8\x8f Time: " .. formatTime(elapsed) -- ⏱️
        OreLabel.Text = "\xf0\x9f\xaa\xa8 Ore Mined: " .. totalOreMined -- 🪨
        EarnLabel.Text = "\xf0\x9f\x92\xb0 Earnings: $" .. totalEarnings -- 💰

        local inv = countInventoryItems()
        local invCount = getTotalOreCount(inv)
        local invValue = calculateEarnings(inv)
        InvLabel.Text = "\xf0\x9f\x8e\x92 Inventory: " .. invCount .. " ore ($" .. invValue .. ")" -- 🎒
    else
        -- Show frozen values
        TimeLabel.Text = "\xe2\x8f\xb1\xef\xb8\x8f Time: " .. frozenTimeStr -- ⏱️
        OreLabel.Text = "\xf0\x9f\xaa\xa8 Ore Mined: " .. (frozenOreCount > 0 and frozenOreCount or totalOreMined) -- 🪨
        EarnLabel.Text = "\xf0\x9f\x92\xb0 Earnings: $" .. (frozenEarnings > 0 and frozenEarnings or totalEarnings) -- 💰

        local inv = countInventoryItems()
        local invCount = getTotalOreCount(inv)
        local invValue = calculateEarnings(inv)
        InvLabel.Text = "\xf0\x9f\x8e\x92 Inventory: " .. invCount .. " ore ($" .. invValue .. ")" -- 🎒
    end
end)

--// Character respawn handling
LocalPlayer.CharacterAdded:Connect(function(char)
    Character = char
    Humanoid = char:WaitForChild("Humanoid")
    HumanoidRootPart = char:WaitForChild("HumanoidRootPart")

    -- Stop farming on death
    if isFarming then
        stopFarming()
        FarmBtn.Text = "\xe2\x9b\x8f\xef\xb8\x8f START FARM" -- ⛏️
        FarmBtn.BackgroundColor3 = Color3.fromRGB(40, 120, 40)
        StatusLabel.Text = "\xf0\x9f\x94\xb4 Status: Died - Stopped" -- 🔴
        StatusLabel.TextColor3 = Color3.fromRGB(200, 50, 50)
    end

    -- Stop fly
    if isFlying then
        stopFly()
        FlyBtn.Text = "\xf0\x9f\x90\xa4 FLY: OFF" -- 🐤
        FlyBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 160)
    end

    removePlatform()
end)

print("[AI Script v0.01] Loaded successfully!")
