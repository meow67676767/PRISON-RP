--[[
    AI Script v0.02
    - Page-based UI (Main / Ore Farm)
    - Mine ore near rocks with platform under player
    - INSIDE ROCK mode toggle (TP inside rock, camera on rock)
    - Detect broken rock by ore in Backpack
    - TP to NPC for selling
    - Fly (IY style), Noclip (IY style)
    - Anti-AFK auto on farm start
    - Stats: time, money, $/hour
    - NO FALL DAMAGE toggle
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local VirtualUser = game:GetService("VirtualUser")

local LocalPlayer = Players.LocalPlayer
local Character = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
local Humanoid = Character:WaitForChild("Humanoid")
local RootPart = Character:WaitForChild("HumanoidRootPart")

-- ═══════════════ SETTINGS ═══════════════
local CAVE_POS = Vector3.new(-424, -8, 246)
local NPC_NAME = "Mineral Buyer"
local ORE_PRICES = {Azurith=54, RawGold=24, RawIron=11, RawCopper=5, Coal=4}
local ORE_NAMES = {"Azurith","RawGold","RawIron","RawCopper","Coal"}
local HIT_COOLDOWN = 0.35
local MINE_DISTANCE = 5
local ROCKS_FOLDER_PATH = "Tasks.Prisoner.Rocks"

-- ═══════════════ STATE ═══════════════
local farming = false
local flying = false
local noclipping = false
local noclipConn = nil
local flyConn = nil
local flyDirection = {f=0, b=0, l=0, r=0, u=0, d=0}
local antiAfkConn = nil
local insideRockMode = false

-- No Fall Damage state
local dmgBlocked = false
local noDmgConn = nil

-- Platform
local platform = nil
local platformConn = nil

-- Stats
local farmStartTime = 0
local totalMoneyEarned = 0
local frozenElapsed = 0

-- ═══════════════ UTILITY ═══════════════
local function getCharacter()
    local char = LocalPlayer.Character
    if char and char:FindFirstChild("HumanoidRootPart") and char:FindFirstChild("Humanoid") and char.Humanoid.Health > 0 then
        return char
    end
    return nil
end

local function getRootPart()
    local char = getCharacter()
    return char and char:FindFirstChild("HumanoidRootPart")
end

local function getBackpack()
    return LocalPlayer:FindFirstChild("Backpack")
end

local function countOre()
    local bp = getBackpack()
    local char = getCharacter()
    local count = 0
    if bp then
        for _, item in pairs(bp:GetChildren()) do
            if table.find(ORE_NAMES, item.Name) then
                count = count + 1
            end
        end
    end
    if char then
        for _, item in pairs(char:GetChildren()) do
            if table.find(ORE_NAMES, item.Name) then
                count = count + 1
            end
        end
    end
    return count
end

local function getRocksFolder()
    local t = workspace:FindFirstChild("Tasks")
    if not t then return nil end
    local p = t:FindFirstChild("Prisoner")
    if not p then return nil end
    return p:FindFirstChild("Rocks")
end

local function findNearestRock(skipList)
    local rocks = getRocksFolder()
    local root = getRootPart()
    if not rocks or not root then return nil end
    
    local nearest = nil
    local nearestDist = math.huge
    
    for _, rock in pairs(rocks:GetChildren()) do
        if rock:IsA("BasePart") then
            if skipList and skipList[rock] then
                continue
            end
            local dist = (rock.Position - root.Position).Magnitude
            if dist < nearestDist then
                nearestDist = dist
                nearest = rock
            end
        end
    end
    return nearest
end

local function getNPCPart()
    local entities = workspace:FindFirstChild("Entities")
    if not entities then return nil end
    local npc = entities:FindFirstChild(NPC_NAME)
    if not npc then return nil end
    return npc:FindFirstChild("HumanoidRootPart") or npc:FindFirstChild("Torso") or npc:FindFirstChild("Head")
end

local function getPickaxe()
    local char = getCharacter()
    if char then
        local pick = char:FindFirstChild("Pickaxe")
        if pick then return pick end
    end
    local bp = getBackpack()
    if bp then
        local pick = bp:FindFirstChild("Pickaxe")
        if pick then return pick end
    end
    return nil
end

-- ═══════════════ ANTI-AFK ═══════════════
local function enableAntiAfk()
    if antiAfkConn then return end
    antiAfkConn = LocalPlayer.Idled:Connect(function()
        VirtualUser:CaptureController()
        VirtualUser:ClickButton2(Vector2.new())
    end)
end

local function disableAntiAfk()
    if antiAfkConn then
        antiAfkConn:Disconnect()
        antiAfkConn = nil
    end
end

-- ═══════════════ NO FALL DAMAGE ═══════════════
local function enableDmgBlock()
    if dmgBlocked then return end
    dmgBlocked = true
    noDmgConn = RunService.Heartbeat:Connect(function()
        local char = getCharacter()
        if char then
            local hum = char:FindFirstChild("Humanoid")
            if hum and hum.Health < hum.MaxHealth then
                hum.Health = hum.MaxHealth
            end
        end
    end)
end

local function disableDmgBlock()
    if not dmgBlocked then return end
    dmgBlocked = false
    if noDmgConn then
        noDmgConn:Disconnect()
        noDmgConn = nil
    end
end

-- ═══════════════ PLATFORM ═══════════════
local function createPlatform(pos)
    if platform then platform:Destroy() end
    platform = Instance.new("Part")
    platform.Name = "AIScriptPlatform"
    platform.Size = Vector3.new(12, 1, 12)
    platform.Position = pos - Vector3.new(0, 4, 0)
    platform.Anchored = true
    platform.Transparency = 0.6
    platform.Material = Enum.Material.ForceField
    platform.BrickColor = BrickColor.new("Cyan")
    platform.CanCollide = true
    platform.Parent = workspace
end

local function removePlatform()
    if platform then
        platform:Destroy()
        platform = nil
    end
    if platformConn then
        platformConn:Disconnect()
        platformConn = nil
    end
end

local function startPlatformFollow(rockRef)
    if platformConn then platformConn:Disconnect() end
    platformConn = RunService.Heartbeat:Connect(function()
        local root = getRootPart()
        if not root or not farming then
            removePlatform()
            return
        end
        if platform and platform.Parent then
            -- Keep platform under the player
            platform.CFrame = CFrame.new(root.Position - Vector3.new(0, 4, 0))
        end
    end)
end

-- ═══════════════ NOCLIP (IY style) ═══════════════
local function startNoclip()
    if noclipConn then return end
    noclipping = true
    noclipConn = RunService.Stepped:Connect(function()
        if not noclipping then return end
        local char = getCharacter()
        if char then
            for _, child in pairs(char:GetDescendants()) do
                if child:IsA("BasePart") and child.CanCollide == true then
                    child.CanCollide = false
                end
            end
        end
    end)
end

local function stopNoclip()
    noclipping = false
    if noclipConn then
        noclipConn:Disconnect()
        noclipConn = nil
    end
end

-- ═══════════════ FLY (IY style) ═══════════════
local flyspeed = 1
local FLYING = false
local flyKeyDown = nil
local flyKeyUp = nil
local BV = nil
local BG = nil

local function IY_FLY()
    FLYING = true
    local root = getRootPart()
    if not root then return end
    local humanoid = getCharacter() and getCharacter():FindFirstChildOfClass("Humanoid")
    
    local CONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
    local lCONTROL = {F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0}
    local SPEED = 0
    
    BG = Instance.new('BodyGyro')
    BV = Instance.new('BodyVelocity')
    BG.P = 9e4
    BG.Parent = root
    BV.Parent = root
    BG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
    BG.CFrame = root.CFrame
    BV.Velocity = Vector3.new(0, 0, 0)
    BV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
    
    if humanoid then humanoid.PlatformStand = true end
    
    flyKeyDown = UserInputService.InputBegan:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.W then CONTROL.F = flyspeed
        elseif input.KeyCode == Enum.KeyCode.S then CONTROL.B = -flyspeed
        elseif input.KeyCode == Enum.KeyCode.A then CONTROL.L = -flyspeed
        elseif input.KeyCode == Enum.KeyCode.D then CONTROL.R = flyspeed
        elseif input.KeyCode == Enum.KeyCode.E then CONTROL.Q = flyspeed * 2
        elseif input.KeyCode == Enum.KeyCode.Q then CONTROL.E = -flyspeed * 2
        end
    end)
    
    flyKeyUp = UserInputService.InputEnded:Connect(function(input, processed)
        if processed then return end
        if input.KeyCode == Enum.KeyCode.W then CONTROL.F = 0
        elseif input.KeyCode == Enum.KeyCode.S then CONTROL.B = 0
        elseif input.KeyCode == Enum.KeyCode.A then CONTROL.L = 0
        elseif input.KeyCode == Enum.KeyCode.D then CONTROL.R = 0
        elseif input.KeyCode == Enum.KeyCode.E then CONTROL.Q = 0
        elseif input.KeyCode == Enum.KeyCode.Q then CONTROL.E = 0
        end
    end)
    
    task.spawn(function()
        repeat task.wait()
            local camera = workspace.CurrentCamera
            if CONTROL.L + CONTROL.R ~= 0 or CONTROL.F + CONTROL.B ~= 0 or CONTROL.Q + CONTROL.E ~= 0 then
                SPEED = 50
            else
                SPEED = 0
            end
            if (CONTROL.L + CONTROL.R) ~= 0 or (CONTROL.F + CONTROL.B) ~= 0 or (CONTROL.Q + CONTROL.E) ~= 0 then
                BV.Velocity = ((camera.CFrame.LookVector * (CONTROL.F + CONTROL.B)) + ((camera.CFrame * CFrame.new(CONTROL.L + CONTROL.R, (CONTROL.F + CONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).p) - camera.CFrame.p)) * SPEED
                lCONTROL = {F = CONTROL.F, B = CONTROL.B, L = CONTROL.L, R = CONTROL.R}
            elseif (CONTROL.L + CONTROL.R) == 0 and (CONTROL.F + CONTROL.B) == 0 and (CONTROL.Q + CONTROL.E) == 0 and SPEED ~= 0 then
                BV.Velocity = ((camera.CFrame.LookVector * (lCONTROL.F + lCONTROL.B)) + ((camera.CFrame * CFrame.new(lCONTROL.L + lCONTROL.R, (lCONTROL.F + lCONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).p) - camera.CFrame.p)) * SPEED
            else
                BV.Velocity = Vector3.new(0, 0, 0)
            end
            BG.CFrame = camera.CFrame
        until not FLYING
        
        if BG then BG:Destroy() BG = nil end
        if BV then BV:Destroy() BV = nil end
        local hum = getCharacter() and getCharacter():FindFirstChildOfClass("Humanoid")
        if hum then hum.PlatformStand = false end
    end)
end

local function IY_NOFLY()
    FLYING = false
    if flyKeyDown then flyKeyDown:Disconnect() flyKeyDown = nil end
    if flyKeyUp then flyKeyUp:Disconnect() flyKeyUp = nil end
    local hum = getCharacter() and getCharacter():FindFirstChildOfClass("Humanoid")
    if hum then hum.PlatformStand = false end
    if BG then BG:Destroy() BG = nil end
    if BV then BV:Destroy() BV = nil end
end

local function startFly()
    if flying then return end
    flying = true
    local ok, err = pcall(function() IY_FLY() end)
    if not ok then
        warn("[FLY] BodyGyro failed, CFrame fallback: " .. tostring(err))
        IY_NOFLY()
        flying = true
        flyDirection = {f=0, b=0, l=0, r=0, u=0, d=0}
        flyConn = RunService.RenderStepped:Connect(function()
            local root = getRootPart()
            if not root or not flying then return end
            local cam = workspace.CurrentCamera
            local cf = cam.CFrame
            local dir = Vector3.new(0,0,0)
            if flyDirection.f == 1 then dir = dir + cf.LookVector end
            if flyDirection.b == 1 then dir = dir - cf.LookVector end
            if flyDirection.r == 1 then dir = dir + cf.RightVector end
            if flyDirection.l == 1 then dir = dir - cf.RightVector end
            if flyDirection.u == 1 then dir = dir + Vector3.new(0,1,0) end
            if flyDirection.d == 1 then dir = dir - Vector3.new(0,1,0) end
            if dir.Magnitude > 0 then root.CFrame = root.CFrame + dir.Unit * 80 * 0.016 end
        end)
    end
end

local function stopFly()
    flying = false
    IY_NOFLY()
    if flyConn then flyConn:Disconnect() flyConn = nil end
end

-- ═══════════════ SELL ORE ═══════════════
local function sellAllOre()
    local root = getRootPart()
    if not root then return 0 end
    
    local npcPart = getNPCPart()
    if not npcPart then return 0 end
    
    root.CFrame = CFrame.new(npcPart.Position + Vector3.new(0, 3, 0))
    task.wait(0.5)
    
    local npc = workspace.Entities:FindFirstChild(NPC_NAME)
    if npc then
        local hrp = npc:FindFirstChild("HumanoidRootPart")
        if hrp then
            local prompt = hrp:FindFirstChild("Prompt")
            if prompt then
                local interact = prompt:FindFirstChild("Interact")
                if interact and interact:FindFirstChild("Event") then
                    interact.Event:FireServer()
                    task.wait(0.3)
                end
            end
        end
    end
    
    local totalEarned = 0
    local sellRemote = ReplicatedStorage:FindFirstChild("Remotes") and ReplicatedStorage.Remotes:FindFirstChild("SellOre")
    if not sellRemote then return 0 end
    
    local bp = getBackpack()
    local char = getCharacter()
    
    for _, oreName in pairs(ORE_NAMES) do
        local amount = 0
        if bp then
            for _, item in pairs(bp:GetChildren()) do
                if item.Name == oreName then amount = amount + 1 end
            end
        end
        if char then
            for _, item in pairs(char:GetChildren()) do
                if item.Name == oreName then amount = amount + 1 end
            end
        end
        if amount > 0 then
            local price = ORE_PRICES[oreName] or 0
            totalEarned = totalEarned + (price * amount)
            pcall(function() sellRemote:FireServer(oreName, amount) end)
            task.wait(0.15)
        end
    end
    return totalEarned
end

-- ═══════════════ STATUS UPDATE ═══════════════
local function updateStatus(text)
    local gui = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("AIScriptGUI")
    if gui then
        local status = gui.MainFrame:FindFirstChild("Status")
        if status then status.Text = text end
    end
end

-- ═══════════════ MINE LOOP ═══════════════
local minedRocks = {}

local function farmLoop()
    minedRocks = {}
    
    -- TP to cave first
    local root = getRootPart()
    if root then
        root.CFrame = CFrame.new(CAVE_POS)
        updateStatus("TP'd to cave...")
        task.wait(1)
    end
    
    while farming do
        root = getRootPart()
        if not root then
            updateStatus("No character, waiting...")
            task.wait(1)
            continue
        end
        
        local rock = findNearestRock(minedRocks)
        if not rock then
            minedRocks = {}
            rock = findNearestRock(nil)
            if not rock then
                updateStatus("No rocks found, waiting...")
                task.wait(1)
                continue
            end
        end
        
        updateStatus("Rock found, preparing...")
        local oreBefore = countOre()
        
        local pickaxe = getPickaxe()
        if not pickaxe then
            updateStatus("No pickaxe!")
            task.wait(1)
            continue
        end
        
        if pickaxe.Parent == getBackpack() then
            local hum = getCharacter() and getCharacter():FindFirstChild("Humanoid")
            if hum then
                hum:EquipTool(pickaxe)
                task.wait(0.5)
                pickaxe = getPickaxe()
            end
        end
        if not pickaxe then
            updateStatus("Pickaxe equip failed!")
            task.wait(1)
            continue
        end
        
        -- Stop noclip while mining
        local wasNoclipping = noclipping
        if noclipping then stopNoclip() end
        
        -- Position player
        local rockPos = rock.Position
        
        if insideRockMode then
            -- INSIDE ROCK: TP inside the rock, camera looks at rock
            root.CFrame = CFrame.new(rockPos)
            createPlatform(rockPos)
        else
            -- NEAR ROCK: stand 5 studs away, platform under feet
            local direction = (rockPos - root.Position).Unit
            local standPos = rockPos - direction * MINE_DISTANCE
            root.CFrame = CFrame.new(standPos, rockPos)
            createPlatform(standPos)
        end
        
        startPlatformFollow(rock)
        task.wait(0.3)
        
        root = getRootPart()
        if not root then
            removePlatform()
            if wasNoclipping then startNoclip() end
            task.wait(1)
            continue
        end
        
        local toolFolder = ReplicatedStorage:FindFirstChild("Remotes") and ReplicatedStorage.Remotes:FindFirstChild("Tool")
        local toolEvent = toolFolder and toolFolder:FindFirstChild("Event")
        if not toolEvent then
            updateStatus("Tool.Event NOT FOUND!")
            removePlatform()
            if wasNoclipping then startNoclip() end
            task.wait(1)
            continue
        end
        
        local char = getCharacter()
        if not char then
            removePlatform()
            if wasNoclipping then startNoclip() end
            task.wait(1)
            continue
        end
        
        local currentPickaxe = char:FindFirstChild("Pickaxe")
        if not currentPickaxe then
            for _, child in pairs(char:GetChildren()) do
                if child:IsA("Tool") or child.Name:lower():find("pick") then
                    currentPickaxe = child
                    break
                end
            end
            if not currentPickaxe then
                removePlatform()
                if wasNoclipping then startNoclip() end
                task.wait(1)
                continue
            end
        end
        
        updateStatus("Mining... (" .. currentPickaxe.Name .. ")")
        
        local hitCount = 0
        local maxHits = 60
        local rockBroken = false
        local noOreHits = 0
        
        while farming and hitCount < maxHits do
            if not rock or rock.Parent == nil then
                rockBroken = true
                break
            end
            local rocksFolder = getRocksFolder()
            if rocksFolder and not rocksFolder:IsAncestorOf(rock) then
                rockBroken = true
                break
            end
            local oreNow = countOre()
            if oreNow > oreBefore then
                rockBroken = true
                break
            end
            
            -- Re-position
            if insideRockMode then
                root.CFrame = CFrame.new(rock.Position)
            else
                rockPos = rock.Position
                local direction = (rockPos - root.Position).Unit
                local standPos = rockPos - direction * MINE_DISTANCE
                root.CFrame = CFrame.new(standPos, rockPos)
            end
            
            currentPickaxe = char:FindFirstChild("Pickaxe")
            if not currentPickaxe then
                for _, child in pairs(char:GetChildren()) do
                    if child:IsA("Tool") or child.Name:lower():find("pick") then
                        currentPickaxe = child
                        break
                    end
                end
                if not currentPickaxe then break end
            end
            
            -- Fire mine remote TWICE
            pcall(function() toolEvent:FireServer("MineOres", currentPickaxe, rock) end)
            pcall(function() toolEvent:FireServer("MineOres", currentPickaxe, rock) end)
            
            hitCount = hitCount + 1
            noOreHits = noOreHits + 1
            
            if noOreHits >= 15 then
                local stillValid = false
                local folder = getRocksFolder()
                if folder then
                    for _, r in pairs(folder:GetChildren()) do
                        if r == rock then stillValid = true break end
                    end
                end
                if not stillValid then break end
                noOreHits = 0
            end
            
            updateStatus("Hitting rock... (" .. hitCount .. ")")
            task.wait(HIT_COOLDOWN)
        end
        
        removePlatform()
        
        if rockBroken then
            minedRocks[rock] = true
            updateStatus("Rock broken! Next...")
        end
        if hitCount >= maxHits and not rockBroken then
            minedRocks[rock] = true
            updateStatus("Rock bugged, skip...")
        end
        
        if wasNoclipping then startNoclip() end
        
        if countOre() >= 20 then
            updateStatus("Selling ore...")
            local earned = sellAllOre()
            totalMoneyEarned = totalMoneyEarned + earned
            minedRocks = {}
            root = getRootPart()
            if root then root.CFrame = CFrame.new(CAVE_POS) end
            task.wait(0.5)
        end
        
        task.wait(0.3)
    end
    
    removePlatform()
end

-- ═══════════════ GUI ═══════════════
local function createGui()
    local old = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("AIScriptGUI")
    if old then old:Destroy() end
    
    local gui = Instance.new("ScreenGui")
    gui.Name = "AIScriptGUI"
    gui.ResetOnSpawn = false
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    
    -- Main Frame
    local frame = Instance.new("Frame")
    frame.Name = "MainFrame"
    frame.Size = UDim2.new(0, 260, 0, 360)
    frame.Position = UDim2.new(0, 10, 0.5, -180)
    frame.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
    frame.BorderSizePixel = 0
    frame.Active = true
    frame.Draggable = true
    frame.Parent = gui
    Instance.new("UICorner", frame).CornerRadius = UDim.new(0, 10)
    
    -- Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 32)
    titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 50)
    titleBar.BorderSizePixel = 0
    titleBar.Parent = frame
    Instance.new("UICorner", titleBar).CornerRadius = UDim.new(0, 10)
    
    local titleLabel = Instance.new("TextLabel")
    titleLabel.Size = UDim2.new(1, -10, 1, 0)
    titleLabel.Position = UDim2.new(0, 10, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "AI Script v0.02"
    titleLabel.TextColor3 = Color3.fromRGB(180, 180, 255)
    titleLabel.Font = Enum.Font.GothamBold
    titleLabel.TextSize = 14
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.Parent = titleBar
    
    -- ═══════════════ PAGE: MAIN ═══════════════
    local mainPage = Instance.new("Frame")
    mainPage.Name = "MainPage"
    mainPage.Size = UDim2.new(1, -16, 1, -40)
    mainPage.Position = UDim2.new(0, 8, 0, 36)
    mainPage.BackgroundTransparency = 1
    mainPage.Parent = frame
    
    -- Ore Farm Button
    local oreBtn = Instance.new("TextButton")
    oreBtn.Size = UDim2.new(1, 0, 0, 45)
    oreBtn.Position = UDim2.new(0, 0, 0, 10)
    oreBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 60)
    oreBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    oreBtn.Font = Enum.Font.GothamBold
    oreBtn.TextSize = 14
    oreBtn.Text = "⛏️ ORE FARM"
    oreBtn.Parent = mainPage
    Instance.new("UICorner", oreBtn).CornerRadius = UDim.new(0, 8)
    
    -- Fly Toggle
    local flyBtn = Instance.new("TextButton")
    flyBtn.Name = "FlyBtn"
    flyBtn.Size = UDim2.new(0.48, 0, 0, 40)
    flyBtn.Position = UDim2.new(0, 0, 0, 65)
    flyBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
    flyBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    flyBtn.Font = Enum.Font.Gotham
    flyBtn.TextSize = 12
    flyBtn.Text = "✈️ FLY"
    flyBtn.Parent = mainPage
    Instance.new("UICorner", flyBtn).CornerRadius = UDim.new(0, 8)
    
    -- Noclip Toggle
    local noclipBtn = Instance.new("TextButton")
    noclipBtn.Name = "NoclipBtn"
    noclipBtn.Size = UDim2.new(0.48, 0, 0, 40)
    noclipBtn.Position = UDim2.new(0.52, 0, 0, 65)
    noclipBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
    noclipBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    noclipBtn.Font = Enum.Font.Gotham
    noclipBtn.TextSize = 12
    noclipBtn.Text = "👻 NOCLIP"
    noclipBtn.Parent = mainPage
    Instance.new("UICorner", noclipBtn).CornerRadius = UDim.new(0, 8)
    
    -- No Fall Damage Toggle
    local dmgBtn = Instance.new("TextButton")
    dmgBtn.Name = "DmgBtn"
    dmgBtn.Size = UDim2.new(1, 0, 0, 40)
    dmgBtn.Position = UDim2.new(0, 0, 0, 115)
    dmgBtn.BackgroundColor3 = Color3.fromRGB(90, 40, 40)
    dmgBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    dmgBtn.Font = Enum.Font.Gotham
    dmgBtn.TextSize = 12
    dmgBtn.Text = "🛡️ NO FALL DMG: OFF"
    dmgBtn.Parent = mainPage
    Instance.new("UICorner", dmgBtn).CornerRadius = UDim.new(0, 8)
    
    -- TP to Cave
    local caveBtn = Instance.new("TextButton")
    caveBtn.Size = UDim2.new(1, 0, 0, 35)
    caveBtn.Position = UDim2.new(0, 0, 0, 165)
    caveBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
    caveBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    caveBtn.Font = Enum.Font.Gotham
    caveBtn.TextSize = 11
    caveBtn.Text = "🕳️ TP TO CAVE"
    caveBtn.Parent = mainPage
    Instance.new("UICorner", caveBtn).CornerRadius = UDim.new(0, 8)
    
    -- Info
    local infoLabel = Instance.new("TextLabel")
    infoLabel.Size = UDim2.new(1, 0, 0, 40)
    infoLabel.Position = UDim2.new(0, 0, 0, 210)
    infoLabel.BackgroundTransparency = 1
    infoLabel.TextColor3 = Color3.fromRGB(100, 100, 130)
    infoLabel.Font = Enum.Font.Gotham
    infoLabel.TextSize = 9
    infoLabel.Text = "Fly: WASD+Q/E | Speed: 1-9\nCtrl+F fly | Ctrl+N noclip"
    infoLabel.TextYAlignment = Enum.TextYAlignment.Top
    infoLabel.Parent = mainPage
    
    -- More coming soon label
    local soonLabel = Instance.new("TextLabel")
    soonLabel.Size = UDim2.new(1, 0, 0, 30)
    soonLabel.Position = UDim2.new(0, 0, 0, 255)
    soonLabel.BackgroundTransparency = 1
    soonLabel.TextColor3 = Color3.fromRGB(80, 80, 100)
    soonLabel.Font = Enum.Font.GothamItalic
    soonLabel.TextSize = 10
    soonLabel.Text = "More modules coming soon..."
    soonLabel.Parent = mainPage
    
    -- ═══════════════ PAGE: ORE FARM ═══════════════
    local orePage = Instance.new("Frame")
    orePage.Name = "OrePage"
    orePage.Size = UDim2.new(1, -16, 1, -40)
    orePage.Position = UDim2.new(0, 8, 0, 36)
    orePage.BackgroundTransparency = 1
    orePage.Visible = false
    orePage.Parent = frame
    
    -- Back button
    local backBtn = Instance.new("TextButton")
    backBtn.Name = "BackBtn"
    backBtn.Size = UDim2.new(0, 25, 0, 18)
    backBtn.Position = UDim2.new(0, 2, 0, 0)
    backBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 80)
    backBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    backBtn.Font = Enum.Font.GothamBold
    backBtn.TextSize = 11
    backBtn.Text = "◀"
    backBtn.Parent = orePage
    Instance.new("UICorner", backBtn).CornerRadius = UDim.new(0, 5)
    
    -- Page title
    local oreTitle = Instance.new("TextLabel")
    oreTitle.Size = UDim2.new(1, -35, 0, 18)
    oreTitle.Position = UDim2.new(0, 30, 0, 0)
    oreTitle.BackgroundTransparency = 1
    oreTitle.Text = "⛏️ ORE FARM"
    oreTitle.TextColor3 = Color3.fromRGB(180, 255, 180)
    oreTitle.Font = Enum.Font.GothamBold
    oreTitle.TextSize = 12
    oreTitle.TextXAlignment = Enum.TextXAlignment.Left
    oreTitle.Parent = orePage
    
    -- Start Farm
    local farmBtn = Instance.new("TextButton")
    farmBtn.Name = "FarmBtn"
    farmBtn.Size = UDim2.new(1, 0, 0, 35)
    farmBtn.Position = UDim2.new(0, 0, 0, 25)
    farmBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 50)
    farmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    farmBtn.Font = Enum.Font.GothamBold
    farmBtn.TextSize = 13
    farmBtn.Text = "⛏️ START FARM"
    farmBtn.Parent = orePage
    Instance.new("UICorner", farmBtn).CornerRadius = UDim.new(0, 8)
    
    -- Sell
    local sellBtn = Instance.new("TextButton")
    sellBtn.Size = UDim2.new(0.48, 0, 0, 30)
    sellBtn.Position = UDim2.new(0, 0, 0, 67)
    sellBtn.BackgroundColor3 = Color3.fromRGB(120, 100, 30)
    sellBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    sellBtn.Font = Enum.Font.Gotham
    sellBtn.TextSize = 11
    sellBtn.Text = "💰 SELL ORE"
    sellBtn.Parent = orePage
    Instance.new("UICorner", sellBtn).CornerRadius = UDim.new(0, 6)
    
    -- Inside Rock Mode
    local insideBtn = Instance.new("TextButton")
    insideBtn.Name = "InsideBtn"
    insideBtn.Size = UDim2.new(0.48, 0, 0, 30)
    insideBtn.Position = UDim2.new(0.52, 0, 0, 67)
    insideBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 100)
    insideBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    insideBtn.Font = Enum.Font.Gotham
    insideBtn.TextSize = 10
    insideBtn.Text = "🪨 INSIDE: OFF"
    insideBtn.Parent = orePage
    Instance.new("UICorner", insideBtn).CornerRadius = UDim.new(0, 6)
    
    -- Stats
    local statsLabel = Instance.new("TextLabel")
    statsLabel.Name = "Stats"
    statsLabel.Size = UDim2.new(1, 0, 0, 70)
    statsLabel.Position = UDim2.new(0, 0, 0, 105)
    statsLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    statsLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
    statsLabel.Font = Enum.Font.Gotham
    statsLabel.TextSize = 11
    statsLabel.TextXAlignment = Enum.TextXAlignment.Left
    statsLabel.Text = "⏱️ Time: 0:00:00\n💵 Earned: $0\n📈 $/Hour: $0\n💎 Ore: 0"
    statsLabel.Parent = orePage
    Instance.new("UICorner", statsLabel).CornerRadius = UDim.new(0, 6)
    
    -- Status
    local statusLabel = Instance.new("TextLabel")
    statusLabel.Name = "Status"
    statusLabel.Size = UDim2.new(1, 0, 0, 22)
    statusLabel.Position = UDim2.new(0, 0, 0, 183)
    statusLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
    statusLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
    statusLabel.Font = Enum.Font.Gotham
    statusLabel.TextSize = 10
    statusLabel.Text = "Ready"
    statusLabel.Parent = orePage
    Instance.new("UICorner", statusLabel).CornerRadius = UDim.new(0, 6)
    
    -- ═══════════════ PAGE NAVIGATION ═══════════════
    local function showPage(pageName)
        mainPage.Visible = (pageName == "main")
        orePage.Visible = (pageName == "ore")
    end
    
    oreBtn.MouseButton1Click:Connect(function()
        showPage("ore")
    end)
    
    backBtn.MouseButton1Click:Connect(function()
        showPage("main")
    end)
    
    -- ═══════════════ BUTTON LOGIC ═══════════════
    
    -- Farm toggle
    farmBtn.MouseButton1Click:Connect(function()
        farming = not farming
        if farming then
            farmBtn.Text = "⏹️ STOP FARM"
            farmBtn.BackgroundColor3 = Color3.fromRGB(160, 50, 50)
            statusLabel.Text = "Farming..."
            statusLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
            farmStartTime = tick()
            totalMoneyEarned = 0
            frozenElapsed = 0
            enableAntiAfk()
            coroutine.wrap(farmLoop)()
        else
            farmBtn.Text = "⛏️ START FARM"
            farmBtn.BackgroundColor3 = Color3.fromRGB(50, 120, 50)
            statusLabel.Text = "Stopped"
            statusLabel.TextColor3 = Color3.fromRGB(255, 150, 150)
            removePlatform()
            if farmStartTime > 0 then
                frozenElapsed = tick() - farmStartTime
            end
        end
    end)
    
    -- Sell
    sellBtn.MouseButton1Click:Connect(function()
        statusLabel.Text = "Selling..."
        task.spawn(function()
            local earned = sellAllOre()
            totalMoneyEarned = totalMoneyEarned + earned
            statusLabel.Text = "Sold! +$" .. tostring(earned)
            task.wait(2)
            if not farming then statusLabel.Text = "Ready"
            else statusLabel.Text = "Farming..." end
        end)
    end)
    
    -- Inside Rock toggle
    insideBtn.MouseButton1Click:Connect(function()
        insideRockMode = not insideRockMode
        if insideRockMode then
            insideBtn.Text = "🪨 INSIDE: ON"
            insideBtn.BackgroundColor3 = Color3.fromRGB(180, 50, 50)
            statusLabel.Text = "Inside rock mode ON"
        else
            insideBtn.Text = "🪨 INSIDE: OFF"
            insideBtn.BackgroundColor3 = Color3.fromRGB(60, 60, 100)
            statusLabel.Text = "Inside rock mode OFF"
        end
    end)
    
    -- TP Cave
    caveBtn.MouseButton1Click:Connect(function()
        local root = getRootPart()
        if root then
            root.CFrame = CFrame.new(CAVE_POS)
        end
    end)
    
    -- Fly
    flyBtn.MouseButton1Click:Connect(function()
        if flying then
            stopFly()
            flyBtn.Text = "✈️ FLY"
            flyBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
        else
            startFly()
            flyBtn.Text = "✈️ FLY: ON"
            flyBtn.BackgroundColor3 = Color3.fromRGB(40, 100, 160)
        end
    end)
    
    -- Noclip
    noclipBtn.MouseButton1Click:Connect(function()
        if noclipping then
            stopNoclip()
            noclipBtn.Text = "👻 NOCLIP"
            noclipBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 90)
        else
            startNoclip()
            noclipBtn.Text = "👻 NOCLIP: ON"
            noclipBtn.BackgroundColor3 = Color3.fromRGB(40, 100, 160)
        end
    end)
    
    -- No Fall Damage
    dmgBtn.MouseButton1Click:Connect(function()
        if dmgBlocked then
            disableDmgBlock()
            dmgBtn.Text = "🛡️ NO FALL DMG: OFF"
            dmgBtn.BackgroundColor3 = Color3.fromRGB(90, 40, 40)
        else
            enableDmgBlock()
            if dmgBlocked then
                dmgBtn.Text = "🛡️ NO FALL DMG: ON"
                dmgBtn.BackgroundColor3 = Color3.fromRGB(40, 130, 40)
            end
        end
    end)
    
    gui.Parent = LocalPlayer:FindFirstChild("PlayerGui")
    return gui
end

-- ═══════════════ INPUT HANDLING ═══════════════
UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    
    if input.KeyCode == Enum.KeyCode.F and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        if flying then stopFly() else startFly() end
    end
    if input.KeyCode == Enum.KeyCode.N and UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) then
        if noclipping then stopNoclip() else startNoclip() end
    end
    
    if input.KeyCode == Enum.KeyCode.W then flyDirection.f = 1 end
    if input.KeyCode == Enum.KeyCode.S then flyDirection.b = 1 end
    if input.KeyCode == Enum.KeyCode.A then flyDirection.l = 1 end
    if input.KeyCode == Enum.KeyCode.D then flyDirection.r = 1 end
    if input.KeyCode == Enum.KeyCode.Space then flyDirection.u = 1 end
    if input.KeyCode == Enum.KeyCode.LeftShift then flyDirection.d = 1 end
    
    if flying then
        local num = input.KeyCode.Value - 0x30
        if num >= 1 and num <= 9 then flyspeed = num end
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.W then flyDirection.f = 0 end
    if input.KeyCode == Enum.KeyCode.S then flyDirection.b = 0 end
    if input.KeyCode == Enum.KeyCode.A then flyDirection.l = 0 end
    if input.KeyCode == Enum.KeyCode.D then flyDirection.r = 0 end
    if input.KeyCode == Enum.KeyCode.Space then flyDirection.u = 0 end
    if input.KeyCode == Enum.KeyCode.LeftShift then flyDirection.d = 0 end
end)

-- ═══════════════ STATS UPDATE ═══════════════
task.spawn(function()
    while true do
        local gui = LocalPlayer:FindFirstChild("PlayerGui") and LocalPlayer.PlayerGui:FindFirstChild("AIScriptGUI")
        if gui then
            local stats = gui.MainFrame:FindFirstChild("OrePage") and gui.MainFrame.OrePage:FindFirstChild("Stats")
            if stats then
                if farming and farmStartTime > 0 then
                    local elapsed = tick() - farmStartTime
                    local hours = math.floor(elapsed / 3600)
                    local mins = math.floor((elapsed % 3600) / 60)
                    local secs = math.floor(elapsed % 60)
                    local timeStr = string.format("%d:%02d:%02d", hours, mins, secs)
                    local perHour = 0
                    if elapsed > 0 then perHour = math.floor(totalMoneyEarned / (elapsed / 3600)) end
                    stats.Text = "⏱️ Time: " .. timeStr .. "\n💵 Earned: $" .. tostring(totalMoneyEarned) .. "\n📈 $/Hour: $" .. tostring(perHour) .. "\n💎 Ore: " .. tostring(countOre())
                elseif not farming and farmStartTime > 0 then
                    local elapsed = frozenElapsed or 0
                    local hours = math.floor(elapsed / 3600)
                    local mins = math.floor((elapsed % 3600) / 60)
                    local secs = math.floor(elapsed % 60)
                    local timeStr = string.format("%d:%02d:%02d", hours, mins, secs)
                    local perHour = 0
                    if elapsed > 0 then perHour = math.floor(totalMoneyEarned / (elapsed / 3600)) end
                    stats.Text = "⏱️ Time: " .. timeStr .. " (stopped)\n💵 Earned: $" .. tostring(totalMoneyEarned) .. "\n📈 $/Hour: $" .. tostring(perHour) .. "\n💎 Ore: " .. tostring(countOre())
                else
                    stats.Text = "⏱️ Time: 0:00:00\n💵 Earned: $0\n📈 $/Hour: $0\n💎 Ore: " .. tostring(countOre())
                end
            end
        end
        task.wait(1)
    end
end)

-- ═══════════════ CHARACTER RESPAWN ═══════════════
LocalPlayer.CharacterAdded:Connect(function(char)
    Character = char
    Humanoid = char:WaitForChild("Humanoid")
    RootPart = char:WaitForChild("HumanoidRootPart")
    if dmgBlocked then
        dmgBlocked = false
        task.wait(1)
        enableDmgBlock()
    end
end)

-- ═══════════════ INIT ═══════════════
createGui()
print("[AI Script v0.02] Loaded!")
