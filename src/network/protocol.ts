// Shared contracts for a FUTURE independent authoritative server. No fake online implementation.
export const PROTOCOL_VERSION=1;
export const NET_RATES={simulationHz:60,inputHz:30,snapshotHz:20,interpolationMs:100,reconnectGraceMs:15000,disconnectDnfMs:60000} as const;
export type RoomPhase='lobby'|'ready'|'countdown'|'racing'|'results'|'closed';
export type RankTier='bronze'|'silver'|'gold'|'platinum'|'diamond'|'master';
export enum InputBits {Drift=1,Jump=2,Item1=4,Item2=8,BackwardItem=16,Reset=32,Discard=64}
export interface InputFrame {seq:number;clientTick:number;steer:number;throttle:number;brake:number;held:number;pressed:number}
export type ClientMessage=
  | {type:'join';version:1;roomId:string;ticket:string;resumeToken?:string}
  | {type:'ready';kartId:string;trackRevision:string}
  | {type:'inputs';frames:InputFrame[];lastSnapshotTick:number}
  | {type:'ping';clientTime:number}
  | {type:'leave'};
export interface KartSnapshot {id:number;position:[number,number,number];velocity:[number,number,number];yaw:number;lap:number;nextCheckpoint:number;progress:number;slots:[string|null,string|null];boostTicks:number;stunTicks:number;lastInputSeq:number}
export type ServerMessage=
  | {type:'joined';roomId:string;playerId:number;resumeToken:string;serverTick:number;seed:number}
  | {type:'phase';phase:RoomPhase;startsAtTick?:number}
  | {type:'snapshot';tick:number;karts:KartSnapshot[];items:{id:number;kind:string;owner:number;position:[number,number,number]}[]}
  | {type:'confirmedEvent';id:number;tick:number;event:'pickup'|'hit'|'checkpoint'|'finish';actor:number;target?:number}
  | {type:'results';finishers:{id:number;timeMs:number|null;points:number;dnf:boolean}[]}
  | {type:'error';code:'VERSION'|'AUTH'|'FULL'|'TIMEOUT'|'INVALID_INPUT';message:string}
  | {type:'pong';clientTime:number;serverTick:number};
export interface MultiplayerTransport {connect(url:string,ticket:string):Promise<void>;send(message:ClientMessage):void;onMessage(listener:(message:ServerMessage)=>void):()=>void;close():void}
export interface AuthoritativeRaceAdapter {applyInput(playerId:number,input:InputFrame):void;stepFixed():void;snapshot():Extract<ServerMessage,{type:'snapshot'}>}
