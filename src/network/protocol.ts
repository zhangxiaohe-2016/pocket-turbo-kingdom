import type { Controls } from "../input/InputManager";
import type { ItemKind } from "../config/game";
export const PROTOCOL_VERSION = 2;
export type LanMode = "quick" | "arena";
export interface Player {
  id: string;
  name: string;
  kart: number;
  ready: boolean;
  connected: boolean;
}
export interface Room {
  mode: LanMode;
  code: string;
  host: string;
  phase: "lobby" | "countdown" | "racing" | "results";
  players: Player[];
}
export interface KartState {
  score: number;
  hitsTaken: number;
  disconnected: boolean;
  id: string;
  position: [number, number, number];
  velocity: [number, number, number];
  yaw: number;
  speed: number;
  steering: number;
  grounded: boolean;
  drift: boolean;
  driftCharge: number;
  driftLevel: number;
  boost: number;
  stun: number;
  invulnerable: number;
  lap: number;
  nextCheckpoint: number;
  lastCheckpoint: number;
  progress: number;
  rank: number;
  finished: boolean;
  finishTime: number;
  lapTimes: number[];
  slots: (ItemKind | null)[];
  rolling: number[];
}
export interface Snapshot {
  type: "snapshot";
  tick: number;
  elapsed: number;
  countdown: number;
  goFlash: number;
  phase: Room["phase"];
  karts: KartState[];
  boxes: number[];
  items: {
    index: number;
    kind: ItemKind;
    position: [number, number, number];
  }[];
}
export type ClientMessage =
  | { type: "join"; version: number; code: string; name: string; kart: number }
  | { type: "mode"; mode: LanMode }
  | { type: "ready"; ready: boolean }
  | { type: "start" }
  | { type: "rematch" }
  | { type: "input"; seq: number; controls: Controls }
  | { type: "ping"; time: number };
export type ServerMessage =
  | { type: "room"; room: Room; you: string; urls: string[] }
  | Snapshot
  | { type: "error"; message: string }
  | { type: "pong"; time: number };
