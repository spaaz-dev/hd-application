--[[
Connected Discord-GitHub
Discord: @spxxz
Roblox: Rxniez [190335717]

Unified Musical Chairs Match Director

This script acts as the central orchestrator for the entire musical chairs game loop.
It manages the full lifecycle of matches including waiting for players, preparing rounds,
handling intro sequences, running active gameplay phases, resolving eliminations, and
finalizing match results.

It coordinates multiple subsystems such as player state management, chair spawning and
seating logic, music timing, round state transitions, intro animations, and reward
distribution. It also includes debugging utilities, watchdog monitoring, and recovery
mechanisms to ensure the game remains stable and synchronized throughout continuous play.

Made by: @spxxz (Discord) / @Rxniez (Roblox)
Date: 04-05-2026
]]

-- services
local Players = game:GetService("Players") -- player list / player events
local ReplicatedStorage = game:GetService("ReplicatedStorage") -- remotes + shared assets
local RunService = game:GetService("RunService") -- heartbeat for watchdog and loop health
local Workspace = game:GetService("Workspace") -- world lookups (chair anchor fallback, etc.)

-- modules from your game
local RoundService = require(game.ServerScriptService.Round.RoundService) -- global round state machine
local RoundStates = require(game.ServerScriptService.Round.RoundStates) -- round state enum table

local ChairService = require(game.ServerScriptService.Chairs.ChairService) -- chair spawn/layout/count sync
local SeatingService = require(game.ServerScriptService.Chairs.SeatingService) -- seat locking/standing locks

local MusicTimingService = require(game.ServerScriptService.Movement.MusicTimingService) -- active-phase music timer
local PlayerService = require(game.ServerScriptService.Player.PlayerService) -- alive/dead/spectator handling

local IntroAnimationService = require(game.ServerScriptService.Introduction.IntroAnimationService) -- intro anim playback
local IntroductionService = require(game.ServerScriptService.Introduction.IntroductionService) -- intro seating/camera locks
local IntroductionSequenceService = require(game.ServerScriptService.Introduction.IntroductionSequenceService) -- narration/sequence event
local IntroTableService = require(game.ServerScriptService.Introduction.IntroTableService) -- intro table spawn/hide
local ChairAnimationResetService = require(game.ServerScriptService.Introduction.ChairAnimationResetService) -- hard reset animations

local MatchResultService = require(game.ServerScriptService.Round.MatchResultService) -- winner record
local MatchRewardService = require(game.ServerScriptService.Round.MatchRewardService) -- coins/xp progression finalize
local MatchEndUiService = require(game.ServerScriptService.Round.MatchEndUiService) -- winner/non-winner UI event

-- required for side-effect usage in gameplay loop (kept visible intentionally)
local _RoundLoopService = require(game.ServerScriptService.Round.RoundLoopService) -- resolves round transitions
local _EliminationService = require(game.ServerScriptService.Elimination.EliminationService) -- elimination flow

-- optional custom director remote for debug/status text
local REMOTES_FOLDER_NAME = "Remotes" -- standard remotes folder name
local DIRECTOR_EVENT_NAME = "MatchDirectorEvent" -- optional event for status/debug payloads

-- build/get remotes folder safely
local function getRemotesFolder()
	local folder = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME) -- try existing folder first
	if folder and folder:IsA("Folder") then -- accept only if it is really a Folder
		return folder -- return existing valid folder
	end

	if folder then -- if wrong type exists with same name
		folder:Destroy() -- remove invalid object to avoid conflicts
	end

	folder = Instance.new("Folder") -- create proper folder
	folder.Name = REMOTES_FOLDER_NAME -- set folder name
	folder.Parent = ReplicatedStorage -- parent in ReplicatedStorage so clients can see it
	return folder -- return newly created folder
end

-- build/get the director event safely
local function getOrCreateDirectorEvent()
	local remotes = getRemotesFolder() -- ensure remotes folder exists
	local existing = remotes:FindFirstChild(DIRECTOR_EVENT_NAME) -- look for existing event

	if existing and existing:IsA("RemoteEvent") then -- if valid event already exists
		return existing -- use it
	end

	if existing then -- if object exists but is wrong class
		existing:Destroy() -- delete wrong object
	end

	local ev = Instance.new("RemoteEvent") -- create remote event
	ev.Name = DIRECTOR_EVENT_NAME -- assign name
	ev.Parent = remotes -- parent into remotes folder
	return ev -- return new event
end

local DirectorEvent = getOrCreateDirectorEvent() -- resolved status/debug event

-- local pseudo-enum for this script's own lifecycle state
local DirectorStates = {
	Booting = "Booting", -- script just started
	WaitingForPlayers = "WaitingForPlayers", -- waiting for min players
	PreparingMatch = "PreparingMatch", -- loading chars, spawning chairs, resets
	RoundIntro = "RoundIntro", -- intro/cinematic or between-round intro
	RoundActive = "RoundActive", -- music + movement phase
	RoundResolving = "RoundResolving", -- elimination and transition resolution
	MatchFinished = "MatchFinished", -- match winner determined
	Cooldown = "Cooldown", -- post-match wait
}

-- config values in one place
local cfg = {
	MinPlayers = 3, -- minimum required to start a match
	MaxPlayers = 13, -- cap players per match
	PostMatchDelay = 15, -- delay after match before next cycle
	BetweenRoundDelay = 1, -- delay before non-round1 active phase
	CharacterReadyTimeout = 10, -- initial timeout waiting for character readiness
	CharacterRetryTimeout = 6, -- second timeout after retry loading
	IntroChairRadius = 12, -- radius used when laying chairs around intro table
	LobbyRecoveryInterval = 1.25, -- debug pulse / recovery cadence while waiting
	WatchdogEnabled = true, -- send periodic debug watchdog payloads
	WatchdogPeriod = 12, -- seconds between watchdog payloads
	EnableVerboseLogs = true, -- local server print toggle
}

-- runtime state table
local runtime = {
	State = DirectorStates.Booting, -- current director state
	ActiveMatch = nil, -- active match snapshot or nil
	StopRequested = false, -- manual stop flag
	LoopIteration = 0, -- how many times top-level loop has cycled
	LastStatusText = "", -- last status string sent to clients
	LastStateChangeAt = os.clock(), -- timestamp of last state transition
	ForcedLobbyRecoveryCount = 0, -- count lobby recoveries performed
	LastWatchdogAt = os.clock(), -- timestamp for watchdog throttle
}

local nextMatchId = 1 -- monotonically increasing match id

-- tiny helpers
local function now()
	return os.clock() -- stable runtime clock
end

local function int(v)
	return math.floor(v) -- basic integer conversion helper
end

local function intRound(v)
	return math.floor(v + 0.5) -- rounded integer helper
end

local function safeName(player)
	if not player then -- nil guard
		return "nil" -- explicit string fallback
	end
	return player.Name -- normal player name
end

local function log(...)
	if cfg.EnableVerboseLogs then -- only print if verbose logging is enabled
		print("[UnifiedMusicalChairs]", ...) -- prefixed log output
	end
end

local function setState(nextState)
	if runtime.State == nextState then -- skip duplicate state sets
		return -- no-op
	end
	runtime.State = nextState -- assign new state
	runtime.LastStateChangeAt = now() -- mark transition time
	log("State ->", nextState) -- print transition for traceability
end

local function stateAge()
	return now() - runtime.LastStateChangeAt -- seconds since state switch
end

local function sendStatus(text)
	if runtime.LastStatusText == text then -- avoid spamming same text continuously
		return -- no-op if unchanged
	end

	runtime.LastStatusText = text -- remember last sent status

	DirectorEvent:FireAllClients({ -- send packet to all clients
		Action = "Status", -- packet kind
		Text = text, -- visible message
		State = runtime.State, -- current director state
		MatchId = runtime.ActiveMatch and runtime.ActiveMatch.MatchId or 0, -- active match id or 0
		Round = runtime.ActiveMatch and runtime.ActiveMatch.RoundNumber or 0, -- active round or 0
	})
end

local function sendDebug(tag, payload)
	if not cfg.EnableVerboseLogs then -- if debug-style logs disabled
		return -- don't spam clients
	end

	DirectorEvent:FireAllClients({ -- send debug packet
		Action = "Debug", -- packet kind
		Tag = tag, -- short label
		Payload = payload, -- arbitrary debug data
	})
end

local function playerCount()
	return #Players:GetPlayers() -- current connected player count
end

local function getPlayersLimited(maxCount)
	local out = {} -- output list
	for i, plr in ipairs(Players:GetPlayers()) do -- iterate connected players
		if i > maxCount then -- stop when limit hit
			break -- break loop
		end
		table.insert(out, plr) -- add player
	end
	return out -- return selected list
end

local function getMatchPlayers()
	return getPlayersLimited(cfg.MaxPlayers) -- central match player fetch with cap
end

local function isCharacterReady(player)
	local char = player.Character -- character reference
	if not char then -- no character means not ready
		return false -- fail
	end

	local hum = char:FindFirstChild("Humanoid") -- humanoid requirement
	local hrp = char:FindFirstChild("HumanoidRootPart") -- root requirement
	return hum ~= nil and hrp ~= nil -- ready only if both exist
end

local function getNotReadyPlayers(playerList)
	local out = {} -- list of not-ready players
	for _, plr in ipairs(playerList) do -- iterate provided list
		if not isCharacterReady(plr) then -- check readiness
			table.insert(out, plr) -- collect non-ready
		end
	end
	return out -- return list
end

local function waitForPlayersReady(playerList, timeoutSec)
	local deadline = now() + timeoutSec -- absolute timeout

	while now() < deadline do -- loop until timeout
		local notReady = getNotReadyPlayers(playerList) -- get non-ready players
		if #notReady == 0 then -- everyone ready
			return true -- success
		end
		task.wait(0.25) -- short polling delay
	end

	return #getNotReadyPlayers(playerList) == 0 -- final post-timeout check
end

local function preparePlayersForMatch(playerList)
	for _, plr in ipairs(playerList) do -- mark all as alive for this match
		PlayerService:SetAlive(plr) -- delegate to PlayerService
	end

	for _, plr in ipairs(playerList) do -- force-load all characters
		if plr.Parent then -- ensure player still connected
			plr:LoadCharacter() -- request character load
		end
	end

	if waitForPlayersReady(playerList, cfg.CharacterReadyTimeout) then -- first readiness pass
		return true -- all good
	end

	local retryList = getNotReadyPlayers(playerList) -- gather still-not-ready players
	if #retryList > 0 then -- if any need retry
		log("Retrying character load for", #retryList, "player(s)") -- debug note
	end

	for _, plr in ipairs(retryList) do -- retry only for lagging players
		if plr.Parent then -- ensure still connected
			plr:LoadCharacter() -- second load attempt
		end
	end

	return waitForPlayersReady(retryList, cfg.CharacterRetryTimeout) -- second pass
end

local function getSeatFromChair(chairModel)
	local primary = chairModel.PrimaryPart -- check primary first
	if primary and primary:IsA("Seat") then -- primary is a seat
		return primary -- return primary seat
	end

	for _, desc in ipairs(chairModel:GetDescendants()) do -- fallback descendant scan
		if desc:IsA("Seat") then -- first seat found
			return desc -- return seat
		end
	end

	return nil -- no seat found
end

local function countChairsAndOccupants()
	local chairCount = 0 -- total chair models counted
	local occupiedCount = 0 -- unique occupied players count
	local counted = {} -- dedupe map by player

	for chairModel in pairs(ChairService:GetAllChairs()) do -- iterate chair registry
		chairCount += 1 -- increment chair count

		local seat = getSeatFromChair(chairModel) -- resolve seat for this chair
		if seat and seat.Occupant then -- if seat has occupant humanoid
			local plr = Players:GetPlayerFromCharacter(seat.Occupant.Parent) -- map humanoid -> player
			if plr and not counted[plr] then -- count player once
				counted[plr] = true -- mark counted
				occupiedCount += 1 -- increment occupied unique player count
			end
		end
	end

	return chairCount, occupiedCount -- return tuple
end

local function getChairAnchorFallback()
	local anchor = Workspace:FindFirstChild("ChairAnchor") -- expected anchor in map
	if anchor and anchor:IsA("BasePart") then -- valid part check
		return anchor.Position -- use anchor position
	end
	return Vector3.new(0, 3, 0) -- fallback center if anchor missing
end

local function getCenterFromFirstPlayer(playerList)
	if #playerList == 0 then -- no players
		return getChairAnchorFallback() -- use fallback anchor
	end

	local first = playerList[1] -- first player in match list
	local char = first.Character -- their character
	if not char then -- if no character available
		return getChairAnchorFallback() -- fallback
	end

	local hrp = char:FindFirstChild("HumanoidRootPart") -- root lookup
	if hrp and hrp:IsA("BasePart") then -- valid root
		return hrp.Position -- use player position as spawn center hint
	end

	return getChairAnchorFallback() -- final fallback
end

local function resetPreMatchState()
	MatchResultService:ClearWinner() -- clear stale winner
	MatchEndUiService:HideResults() -- hide old match-end UI panels

	SeatingService:UnlockSeatInteraction() -- allow seat usage
	SeatingService:UnlockSeating() -- open seating
	SeatingService:UnlockStanding() -- remove standing locks

	ChairAnimationResetService:HardResetForAllPlayers() -- reset any lingering animations
end

local function initializeRoundTrackingSafe()
	if typeof(RoundService.StartRound) ~= "function" then -- defensive check
		return -- no-op if method missing
	end

	local ok, err = pcall(function()
		RoundService:StartRound() -- setup alive tracking in RoundService
	end)

	if not ok then -- report startup failures
		warn("[UnifiedMusicalChairs] RoundService:StartRound failed:", err)
	end
end

local function beginMatchSnapshot(playersAtStart)
	runtime.ActiveMatch = { -- create active match metadata
		MatchId = nextMatchId, -- assign id
		RoundNumber = 0, -- round number starts at 0 until first round enters
		StartedAt = now(), -- timestamp start
		PlayersAtStart = playersAtStart, -- initial size
	}
	nextMatchId += 1 -- increment id seed for next match
end

local function setRuntimeRound(roundNumber)
	if runtime.ActiveMatch then -- ensure match exists
		runtime.ActiveMatch.RoundNumber = roundNumber -- assign current round
	end
end

local function endMatchSnapshot()
	runtime.ActiveMatch = nil -- clear active match metadata
end

local function respawnAllCurrentPlayersToLobby(reason)
	log("Lobby recovery:", reason) -- debug reason
	runtime.ForcedLobbyRecoveryCount += 1 -- increment recovery counter

	for _, plr in ipairs(Players:GetPlayers()) do -- iterate connected players
		PlayerService:RespawnToLobby(plr) -- use existing respawn helper
	end
end

local function waitForEnoughPlayers()
	setState(DirectorStates.WaitingForPlayers) -- enter waiting state
	RoundService:SetState(RoundStates.Lobby) -- enforce lobby state
	sendStatus("Waiting for players...") -- status text

	local didRecovery = false -- one-time recovery guard
	local lastPulseAt = now() -- debug pulse timer

	while playerCount() < cfg.MinPlayers do -- block until enough players
		if not didRecovery then -- perform one immediate recovery at entry
			respawnAllCurrentPlayersToLobby("Below min players while waiting")
			didRecovery = true
		end

		if now() - lastPulseAt >= cfg.LobbyRecoveryInterval then -- timed debug pulse
			lastPulseAt = now() -- reset pulse mark
			sendDebug("WaitingPulse", {
				Players = playerCount(),
				Need = cfg.MinPlayers,
				Recoveries = runtime.ForcedLobbyRecoveryCount,
			})
		end

		task.wait(1) -- one-second poll
	end

	sendStatus("Enough players found.") -- transition note
end

local function playRoundOneIntro()
	setState(DirectorStates.RoundIntro) -- state transition
	sendStatus("Round 1 intro sequence...") -- status text

	IntroTableService:Show() -- spawn intro table prop

	local center = IntroTableService:GetCenter() -- read intro table center
	if center then -- if table center exists
		ChairService:LayoutForIntro(center, cfg.IntroChairRadius) -- rotate chairs inward around table
	end

	IntroductionService:Start() -- lock players and seat setup for intro
	task.wait(0.15) -- short settle

	local timings = IntroductionSequenceService:Start() -- start narration/sequence
	task.wait(timings.AnimationStartDelay) -- wait before playing intro chair animation
	IntroAnimationService:Play() -- play intro animations for seated players

	task.wait(math.max(0, timings.TotalDuration - timings.AnimationStartDelay)) -- wait rest of cinematic duration

	IntroAnimationService:Stop() -- stop intro animation system
	IntroductionSequenceService:Stop() -- stop sequence system
	IntroductionService:Stop() -- release intro locks
	ChairAnimationResetService:HardResetForAllPlayers() -- hard reset tracks

	SeatingService:ForceAllPlayersToStand() -- make sure everyone stands for gameplay transition

	IntroTableService:Hide() -- remove intro table
	ChairService:LayoutForGameplay() -- restore normal chair layout
end

local function startRegularRoundIntro(roundNumber)
	setState(DirectorStates.RoundIntro) -- intro state for non-round1 transition
	sendStatus(("Round %d preparing..."):format(roundNumber)) -- status text
	task.wait(cfg.BetweenRoundDelay) -- round transition delay

	if RoundService:IsState(RoundStates.Introduction) then -- still in intro state
		ChairAnimationResetService:HardResetForAllPlayers() -- clean transitions
	end
end

local function beginActiveRound(roundNumber)
	setState(DirectorStates.RoundActive) -- active phase state
	sendStatus(("Round %d active..."):format(roundNumber)) -- status text

	if not RoundService:IsState(RoundStates.Active) then -- ensure active state is set
		RoundService:SetState(RoundStates.Active) -- move to active
	end

	MusicTimingService:Start() -- start music timing service (handles stop + elimination)
end

local function waitForRoundToResolve()
	setState(DirectorStates.RoundResolving) -- resolving state
	sendStatus("Resolving round...") -- status message

	while RoundService:IsState(RoundStates.Active) or RoundService:IsState(RoundStates.Elimination) do -- wait while round still running
		task.wait(0.25) -- poll interval

		local chairs, occupied = countChairsAndOccupants() -- optional debug data
		sendDebug("RoundResolveHeartbeat", {
			Chairs = chairs,
			Occupied = occupied,
			State = RoundService:GetState(),
		})
	end
end

local function finalizeMatchSummary()
	local winner = MatchResultService:GetWinner() -- winner from result service
	local winnerName = winner and winner.Name or "No Winner" -- safe winner text

	setState(DirectorStates.MatchFinished) -- mark match finished
	sendStatus(("Match finished. Winner: %s"):format(winnerName)) -- user-facing summary

	sendDebug("MatchSummary", { -- debug payload with snapshot details
		MatchId = runtime.ActiveMatch and runtime.ActiveMatch.MatchId or 0,
		RoundsPlayed = runtime.ActiveMatch and runtime.ActiveMatch.RoundNumber or 0,
		Winner = winnerName,
		DurationSec = runtime.ActiveMatch and intRound(now() - runtime.ActiveMatch.StartedAt) or 0,
		PlayersAtStart = runtime.ActiveMatch and runtime.ActiveMatch.PlayersAtStart or 0,
	})
end

local function runSingleMatch()
	setState(DirectorStates.PreparingMatch) -- preparing state
	sendStatus("Preparing match...") -- status text

	local matchPlayers = getMatchPlayers() -- choose players for this match
	if #matchPlayers < cfg.MinPlayers then -- recheck safety before heavy setup
		sendStatus("Not enough players anymore, returning to lobby...")
		return
	end

	beginMatchSnapshot(#matchPlayers) -- create match metadata
	resetPreMatchState() -- clean stale systems

	local readyOk = preparePlayersForMatch(matchPlayers) -- load and verify characters
	if not readyOk then -- continue but log warning if not perfect
		warn("[UnifiedMusicalChairs] Some players were still not ready after retry window.")
	end

	task.wait(1) -- small settle time
	initializeRoundTrackingSafe() -- initialize round tracking internals
	MatchRewardService:BeginMatch(matchPlayers) -- begin reward/progression session

	local chairCount = math.clamp(#matchPlayers, 1, cfg.MaxPlayers) -- match chairs = players at match start
	local center = getCenterFromFirstPlayer(matchPlayers) -- choose center for initial chair ring
	ChairService:SpawnChairs(chairCount, center) -- spawn chairs
	SeatingService:BindChairs() -- bind seat occupancy listeners

	setRuntimeRound(1) -- runtime round = 1
	RoundService:SetState(RoundStates.Introduction) -- enter intro state
	playRoundOneIntro() -- run cinematic round1 intro

	if RoundService:IsState(RoundStates.Introduction) then -- if still in intro (not interrupted)
		beginActiveRound(1) -- start active phase
	end

	while not runtime.StopRequested do -- main per-match round loop
		waitForRoundToResolve() -- wait until active/elimination ends

		if RoundService:IsState(RoundStates.RoundEnd) then -- match complete
			finalizeMatchSummary() -- produce final summary
			return -- exit match routine
		end

		if RoundService:IsState(RoundStates.Introduction) then -- next round requested
			local nextRound = (runtime.ActiveMatch and runtime.ActiveMatch.RoundNumber or 1) + 1 -- increment round
			setRuntimeRound(nextRound) -- set runtime round
			startRegularRoundIntro(nextRound) -- run non-round1 intro transition

			if RoundService:IsState(RoundStates.Introduction) then -- if still valid
				beginActiveRound(nextRound) -- begin active phase for this round
			end
		else
			task.wait(0.2) -- fallback short wait if state is in-between
		end
	end
end

local function onCharacterAdded(player, character)
	PlayerService:HandleCharacterAdded(player, character) -- delegate to existing player lifecycle logic
end

local function onPlayerAdded(player)
	PlayerService:HandlePlayerJoin(player) -- join handling (alive/spectator assignment)

	player.CharacterAdded:Connect(function(character) -- bind character spawn
		onCharacterAdded(player, character) -- delegate spawn handling
	end)
end

local function onPlayerRemoving(player)
	PlayerService:HandlePlayerRemoving(player) -- cleanup on leave
end

local function runWatchdog()
	if not cfg.WatchdogEnabled then -- skip watchdog if disabled
		return
	end

	if now() - runtime.LastWatchdogAt < cfg.WatchdogPeriod then -- throttle watchdog cadence
		return
	end

	runtime.LastWatchdogAt = now() -- reset watchdog clock

	sendDebug("DirectorWatchdog", { -- heartbeat debug payload
		State = runtime.State,
		Players = playerCount(),
		LoopIteration = runtime.LoopIteration,
		StateAgeSec = intRound(stateAge()),
		MatchId = runtime.ActiveMatch and runtime.ActiveMatch.MatchId or 0,
		Round = runtime.ActiveMatch and runtime.ActiveMatch.RoundNumber or 0,
		Recoveries = runtime.ForcedLobbyRecoveryCount,
	})
end

RunService.Heartbeat:Connect(function()
	runWatchdog() -- periodic health snapshot
end)

local function runDirectorLoop()
	setState(DirectorStates.Booting) -- initial state
	sendStatus("Booting match director...") -- initial status

	while not runtime.StopRequested do -- infinite director loop until manual stop
		runtime.LoopIteration += 1 -- increment iteration count

		waitForEnoughPlayers() -- block until enough players
		if runtime.StopRequested then -- stop check after waiting
			break
		end

		log("Starting match, loop iteration", runtime.LoopIteration) -- log start
		runSingleMatch() -- run one full match lifecycle

		setState(DirectorStates.Cooldown) -- post-match cooldown state
		sendStatus("Match cooldown...") -- status text
		task.wait(cfg.PostMatchDelay) -- cooldown wait

		if playerCount() < cfg.MinPlayers then -- if players dipped below minimum
			RoundService:SetState(RoundStates.Lobby) -- enforce lobby state
			sendStatus("Player count dropped, waiting again...") -- status text
			respawnAllCurrentPlayersToLobby("Post-match count below min") -- one cleanup pass
		end

		endMatchSnapshot() -- clear active snapshot before next loop
	end
end

Players.PlayerAdded:Connect(onPlayerAdded) -- bind join event
Players.PlayerRemoving:Connect(onPlayerRemoving) -- bind leave event

for _, plr in ipairs(Players:GetPlayers()) do -- bind current players for hot-start safety
	onPlayerAdded(plr) -- run same join logic
	if plr.Character then -- if character already exists
		onCharacterAdded(plr, plr.Character) -- run character-added path once
	end
end

task.spawn(runDirectorLoop) -- start loop in background thread

_G.StopUnifiedMatchDirector = function()
	runtime.StopRequested = true -- set stop flag
	sendStatus("Director stop requested.") -- status text
	log("Stop requested from _G.StopUnifiedMatchDirector") -- server log
end

_G.GetUnifiedMatchDirectorState = function()
	return { -- return state snapshot for command bar inspection
		State = runtime.State,
		MatchId = runtime.ActiveMatch and runtime.ActiveMatch.MatchId or 0,
		Round = runtime.ActiveMatch and runtime.ActiveMatch.RoundNumber or 0,
		Players = playerCount(),
		LoopIteration = runtime.LoopIteration,
		StopRequested = runtime.StopRequested,
		StateAgeSec = intRound(stateAge()),
		Recoveries = runtime.ForcedLobbyRecoveryCount,
	}
end
