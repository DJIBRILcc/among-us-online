javascript
const GameLoop = require('../game/GameLoop');
const MapData = require('../game/MapData');
const AntiCheat = require('../game/AntiCheat');

class RoomManager {
    constructor(io) {
        this.io = io;
        this.rooms = new Map(); // key: roomCode, value: RoomInstance
    }

    handleConnection(socket) {
        socket.on('createGame', (data) => {
            const code = Math.random().toString(36).substring(2, 8).toUpperCase();
            const room = new Room(code, socket.id, this.io, this);
            this.rooms.set(code, room);
            room.join(socket, data.playerName);
            socket.emit('gameCreated', { roomCode: code, settings: room.settings });
        });

        socket.on('joinGame', (data) => {
            const room = this.rooms.get(data.roomCode?.toUpperCase());
            if (!room) return socket.emit('joinError', "La sala no existe.");
            if (room.players.size >= room.settings.maxPlayers) return socket.emit('joinError', "Sala llena.");
            if (room.gameState.status !== 'LOBBY') return socket.emit('joinError', "Partida ya iniciada.");
            
            room.join(socket, data.playerName);
        });

        socket.on('disconnect', () => {
            this.rooms.forEach((room, code) => {
                if (room.players.has(socket.id)) {
                    room.leave(socket.id);
                }
            });
        });

        socket.on('playerMove', (data) => this.getRoomBySocket(socket)?.handleMove(socket.id, data));
        socket.on('updateSettings', (data) => this.getRoomBySocket(socket)?.handleUpdateSettings(socket.id, data));
        socket.on('startGame', () => this.getRoomBySocket(socket)?.handleStartGame(socket.id));
        socket.on('requestKill', (targetId) => this.getRoomBySocket(socket)?.handleKill(socket.id, targetId));
        socket.on('reportCorpse', () => this.getRoomBySocket(socket)?.handleReport(socket.id));
        socket.on('submitVote', (targetId) => this.getRoomBySocket(socket)?.handleVote(socket.id, targetId));
        socket.on('completeTaskStep', (taskId) => this.getRoomBySocket(socket)?.handleTaskStep(socket.id, taskId));
        socket.on('triggerSabotage', (type) => this.getRoomBySocket(socket)?.handleTriggerSabotage(socket.id, type));
        socket.on('resolveSabotage', () => this.getRoomBySocket(socket)?.handleResolveSabotage(socket.id));
        socket.on('chatMessage', (msg) => this.getRoomBySocket(socket)?.handleChat(socket.id, msg));
    }

    getRoomBySocket(socket) {
        for (const room of this.rooms.values()) {
            if (room.players.has(socket.id)) return room;
        }
        return null;
    }
}

class Room {
    constructor(id, hostId, io, manager) {
        this.id = id;
        this.hostId = hostId;
        this.io = io;
        this.manager = manager;
        this.players = new Map();
        this.gameLoop = new GameLoop(this);
        
        this.settings = {
            maxPlayers: 10,
            impostorCount: 2,
            mapSelection: "THE_SKELD",
            gameMode: "classic",
            playerSpeed: 250,
            crewVision: 1.0,
            impostorVision: 1.5,
            killCooldown: 25,
            killDistance: "medium",
            emergencyMeetings: 1,
            discussionTime: 15,
            votingTime: 30,
            anonymousVotes: false,
            confirmEjects: true,
            commonTasks: 1,
            shortTasks: 2,
            longTasks: 1
        };

        this.gameState = {
            status: "LOBBY",
            sabotage: { active: false, type: null, countdown: 0 },
            modeTimer: 0,
            votes: {},
            discussionTimer: 0
        };
    }

    join(socket, name) {
        const colors = ["#ff0000", "#0000ff", "#00ff00", "#ffff00", "#ff00ff", "#00ffff", "#ff7f00", "#7f3f00", "#ffffff", "#7f00ff"];
        const playerColor = colors[this.players.size % colors.length];
        
        const player = {
            id: socket.id,
            name: name || `Tripulante_${Math.floor(Math.random()*900+100)}`,
            color: playerColor,
            skin: "default",
            hat: "none",
            x: 0, y: 0,
            dir: "right",
            isDead: false,
            role: "crewmate",
            tasks: [],
            meetingsLeft: this.settings.emergencyMeetings,
            nextKillAvailable: 0
        };

        this.players.set(socket.id, player);
        socket.join(this.id);
        
        this.io.to(this.id).emit('lobbyUpdate', {
            players: Array.from(this.players.values()),
            hostId: this.hostId
        });
    }

    leave(id) {
        this.players.delete(id);
        if (id === this.hostId && this.players.size > 0) {
            this.hostId = this.players.keys().next().value;
        }
        if (this.players.size === 0) {
            this.gameLoop.stop();
            this.manager.rooms.delete(this.id);
        } else {
            this.io.to(this.id).emit('lobbyUpdate', {
                players: Array.from(this.players.values()),
                hostId: this.hostId
            });
            this.checkWinConditions();
        }
    }

    handleMove(id, data) {
        const player = this.players.get(id);
        if (!player) return;
        
        const now = Date.now();
        const dt = Math.min((now - (player.lastMoveTime || now - 30)) / 1000, 0.1);
        player.lastMoveTime = now;

        if (AntiCheat.validateMovement(player, data.x, data.y, this.settings.playerSpeed, dt)) {
            player.x = data.x;
            player.y = data.y;
            player.dir = data.dir;
        }
    }

    handleUpdateSettings(id, newSettings) {
        if (id !== this.hostId || this.gameState.status !== 'LOBBY') return;
        this.settings = { ...this.settings, ...newSettings };
        this.io.to(this.id).emit('settingsUpdated', this.settings);
    }

    handleStartGame(id) {
        if (id !== this.hostId || this.gameState.status !== 'LOBBY') return;
        if (this.players.size < this.settings.impostorCount + 1) return;

        const pArray = Array.from(this.players.values());
        let assignedImpostors = 0;
        while (assignedImpostors < this.settings.impostorCount) {
            const randIdx = Math.floor(Math.random() * pArray.length);
            if (pArray[randIdx].role !== 'impostor') {
                pArray[randIdx].role = 'impostor';
                assignedImpostors++;
            }
        }

        const currentMap = MapData[this.settings.mapSelection];
        const now = Date.now();

        this.players.forEach(p => {
            p.x = currentMap.spawn.x;
            p.y = currentMap.spawn.y;
            p.isDead = false;
            p.nextKillAvailable = now + 10000;
            
            p.tasks = [];
            const commonPool = currentMap.tasks.filter(t => t.type === 'common');
            const shortPool = currentMap.tasks.filter(t => t.type === 'short');
            
            if (commonPool.length && this.settings.commonTasks > 0) p.tasks.push({ ...commonPool[0], done: false });
            for (let i = 0; i < this.settings.shortTasks && i < shortPool.length; i++) {
                p.tasks.push({ ...shortPool[i], done: false });
            }
        });

        this.gameState.status = "IN_GAME";
        if (this.settings.gameMode === 'hideNSeek') {
            this.gameState.modeTimer = 180;
        }

        this.players.forEach(p => {
            this.io.to(p.id).emit('gameStarted', {
                role: p.role,
                tasks: p.tasks,
                players: this.getPackedPlayers().map(opp => {
                    if (p.role !== 'impostor') return { ...opp, role: 'unknown' };
                    return opp;
                })
            });
        });

        this.gameLoop.start();
    }

    handleKill(killerId, victimId) {
        if (this.gameState.status !== 'IN_GAME') return;
        const killer = this.players.get(killerId);
        const victim = this.players.get(victimId);
        const now = Date.now();

        if (AntiCheat.validateKill(killer, victim, this.settings.killDistance, now)) {
            victim.isDead = true;
            killer.nextKillAvailable = now + (this.settings.killCooldown * 1000);
            
            this.io.to(this.id).emit('playerDied', { victimId: victim.id, x: victim.x, y: victim.y });
            this.checkWinConditions();
        }
    }

    handleReport(reporterId) {
        if (this.gameState.status !== 'IN_GAME') return;
        const reporter = this.players.get(reporterId);
        if (!reporter || reporter.isDead) return;

        this.startMeeting(`¡Un cadáver ha sido reportado por ${reporter.name}!`);
    }

    startMeeting(reason) {
        this.gameState.status = "DISCUSSION";
        this.gameState.votes = {};
        this.io.to(this.id).emit('meetingCalled', { reason: reason, discussionTime: this.settings.discussionTime });
        
        setTimeout(() => {
            this.gameState.status = "MEETING";
            this.io.to(this.id).emit('votingStarted', { votingTime: this.settings.votingTime });
            
            setTimeout(() => {
                this.evaluateVotes();
            }, this.settings.votingTime * 1000);

        }, this.settings.discussionTime * 1000);
    }

    handleVote(voterId, targetId) {
        if (this.gameState.status !== 'MEETING') return;
        const voter = this.players.get(voterId);
        if (!voter || voter.isDead || this.gameState.votes[voterId]) return;

        this.gameState.votes[voterId] = targetId;
        this.io.to(this.id).emit('playerVoted', { voterId: voterId, anonymous: this.settings.anonymousVotes });
    }

    evaluateVotes() {
        if (this.gameState.status !== 'MEETING') return;

        const tally = {};
        let skipCount = 0;

        Object.values(this.gameState.votes).forEach(v => {
            if (v === 'skip') skipCount++;