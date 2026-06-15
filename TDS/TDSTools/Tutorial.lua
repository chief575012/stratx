local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RemoteFunction = if not GameSpoof then ReplicatedStorage:WaitForChild("RemoteFunction") else SpoofEvent
local RemoteEvent = if not GameSpoof then ReplicatedStorage:WaitForChild("RemoteEvent") else SpoofEvent
local UtilitiesConfig = StratXLibrary.UtilitiesConfig
local TDS = Strat.new()

TDS:Map("Tutorial", true, "Tutorial")

if not CheckPlace() then
    return
end

function WaitSpotlight()
    repeat
        task.wait()
    until LocalPlayer.PlayerGui.ReactGameTutorial.Frame.Spotlight and LocalPlayer.PlayerGui.ReactGameTutorial.Frame.Spotlight.Visible
    task.wait(.5)
end

local SelectedTower = {"Scout","Sniper","Demoman","Medic","Minigunner",}
for i,v in next, SelectedTower do
    StratXLibrary.TowerInfo[v] = {maintab:Section(v.." : 0"), 0, v}
end

TimeWaveWait(1,0,0,true)
WaitSpotlight()
RemoteEvent:FireServer("Hotbar", "Click", 1)
TDS:Place("Scout", 7.125424861907959, 17.655710220336914, -26.398717880249023, 1, 0, 0, true, 0, 0, 0)

TimeWaveWait(2,0,0,true)
WaitSpotlight()
RemoteEvent:FireServer("Hotbar", "Click", 2)
TDS:Place("Sniper", 13.23947811126709, 20.111862182617188, -2.1784472465515137, 2, 0, 0, true, 0, 0, 0)

TimeWaveWait(3,0,0,true)
WaitSpotlight()
RemoteEvent:FireServer("Hotbar", "Click", 3)
TDS:Place("Demoman", 21.042768478393555, 18.15481185913086, -17.380836486816406, 3, 0, 0, true, 0, 0, 0)

TimeWaveWait(4,0,0,true)
task.wait(12)
TDS:Upgrade(3, 4, 0, 0, true, 1)
TDS:Upgrade(3, 4, 0, 0, true, 1)
TDS:Upgrade(2, 4, 0, 0, true, 1)
task.wait(0.5)
TDS:Upgrade(1, 4, 0, 0, true, 1)
TDS:Upgrade(1, 4, 0, 0, true, 1)

TimeWaveWait(5,0,0,true)
WaitSpotlight()
RemoteEvent:FireServer("Hotbar", "Click", 4)
TDS:Place("Medic", 23.742952346801758, 17.891376495361328, 16.688644409179688, 5, 0, 0, true, 0, 0, 0)

TimeWaveWait(6,0,0,true)
task.wait(14)
TDS:Sell(4, 6, 0, 0, true)
task.wait(0.5)
TDS:Sell(1, 6, 0, 0, true)
task.wait(2)
RemoteEvent:FireServer("Hotbar", "Click", 5)
TDS:Place("Minigunner", 23.696807861328125, 17.8949031829834, -1.798863172531128, 6, 0, 0, true, 0, 0, 0)