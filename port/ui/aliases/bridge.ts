// calfNXT macOS — host bridge client.
//
// Copyright (C) 2026 Matt Hardy — GPL-3.0-or-later.
//
// Transport is the in-process WKWebView bridge (webkit.messageHandlers.auxHost
// + window.__auxbridge). Values on {t:"set"} and {t:"param"} stay plain
// (dB/Hz); the native WebEditor converts to VST-normalized via the Parameter.
// This module also installs the window.__auxbridge shim that adapts the
// auxVST wire protocol (params JSON frame + base64 CNXB viz batch) to the
// upstream calfNXT dispatch (__calfnxtOnHost / __calfnxtHostQ).
import type { IrNode } from '../../calfnxt/ui/src/utils/irTypes';

export type calfNXTMsg =
  | { t: 'begin'; id: number }
  | { t: 'end'; id: number }
  | { t: 'set'; id: number; v: number }
  | { t: 'param'; id: number; v?: number }
  | { t: 'sync' }
  | { t: 'viewport'; w: number; h: number }
  | { t: '_diag'; msg?: string; w?: number; h?: number }
  | { t: 'io'; ch: number; in?: number; out?: number }
  | { t: 'viz'; id: string; kind: 'levels' | 'unit' | 'spectrum' | 'gains' | 'corr' | 'gonio' | 'envelope' | 'pitch' | 'midi' | 'gr' | 'bandio' | 'point' | 'tempo' | 'shape' | 'hz' | 'ctrl' | 'lfo' | 'response' | 'comb' | 'wave'; v: number[] | Float32Array }
  | { t: 'vizcfg'; id: string; bins?: number }
  | { t: 'vizhz'; hz: number }
  | { t: 'midi'; cmd: string }
  | { t: 'ir'; cmd: string; path?: string; root?: string; sel?: string; status?: string; tree?: IrNode[]; open?: string[]; scroll?: number };

/** Plain float from a host→UI param message (`v`). */
export function plainFromMsg(msg: { v?: number }): number | undefined {
  return typeof msg.v === 'number' && Number.isFinite(msg.v) ? msg.v : undefined;
}

declare global {
  interface Window {
    __calfnxtOnHost?: (msg: calfNXTMsg) => void;
    __calfnxtHostQ?: calfNXTMsg[];
    __calfnxtVizDump?: Record<string, number[] | Float32Array>;
    __calfnxtDumpViz?: () => string;
    /** Injected by the native side when AUXVST_DEBUG is set. */
    __auxvstDebug?: boolean;
    /** auxVST native entry point (installed below). */
    __auxbridge?: { _recv: (msg: unknown) => void; _recvBin: (b64: string) => void };
  }
}

function vizDumpBag(): Record<string, number[] | Float32Array> {
  if (!window.__calfnxtVizDump) window.__calfnxtVizDump = {};
  return window.__calfnxtVizDump;
}

/** True for number[] or typed-array viz payloads (binary path uses Float32Array). */
export function isVizSamples(v: unknown): v is ArrayLike<number> {
  return (
    Array.isArray(v) ||
    (typeof ArrayBuffer !== 'undefined' && ArrayBuffer.isView(v) && !(v instanceof DataView))
  );
}

function vizSamplesForDump(v: ArrayLike<number>): number[] | Float32Array {
  if (v instanceof Float32Array) return v;
  if (Array.isArray(v)) return (v as number[]).slice();
  return Array.from(v);
}

function installVizDumpApi(): void {
  window.__calfnxtDumpViz = () => {
    const bag = vizDumpBag();
    const jsonReady: Record<string, number[]> = {};
    for (const [k, v] of Object.entries(bag)) jsonReady[k] = Array.from(v);
    const json = JSON.stringify(jsonReady, null, 2);
    try {
      void navigator.clipboard?.writeText(json);
    } catch {
      /* WebKit may deny clipboard without a gesture — still return the string. */
    }
    console.log(json);
    return json;
  };
}

installVizDumpApi();

// ---------------------------------------------------------------------------
// auxVST ParamBridge shim. The native side speaks the auxVST wire protocol:
//   params:  __auxbridge._recv({type:'params', values:{id: plain, …}})
//   viz:     __auxbridge._recvBin(base64 CNXB batch of CNXV frames)
// calfNXT carries PLAIN values (dB/Hz) in the params frame — the native
// WebEditor converts at the controller boundary (initial sync is
// pushAllParams).

type VizKind = Extract<calfNXTMsg, { t: 'viz' }>['kind'];

function deliverToUi(msg: calfNXTMsg): void {
  if (window.__calfnxtOnHost) window.__calfnxtOnHost(msg);
  else (window.__calfnxtHostQ = window.__calfnxtHostQ || []).push(msg);
}

/** Decode one CNXB batch (see port/common/viz_bin.h) and deliver per-frame
    {t:'viz', id, kind, v:Float32Array} messages, like the upstream web host. */
function decodeCnxb(b64: string): void {
  const s = atob(b64);
  const u8 = new Uint8Array(s.length);
  for (let i = 0; i < s.length; ++i) u8[i] = s.charCodeAt(i);
  // CNXB: 'C','N','X','B', version u8, reserved[3], frameCount u32 LE
  if (u8.length < 12 || u8[0] !== 0x43 || u8[1] !== 0x4e || u8[2] !== 0x58 || u8[3] !== 0x42)
    return;
  const dv = new DataView(u8.buffer, u8.byteOffset, u8.byteLength);
  const nFrames = dv.getUint32(8, true);
  let o = 12;
  for (let f = 0; f < nFrames; ++f) {
    // CNXV: 'C','N','X','V', version u8, idLen u8, kindLen u8, fmt u8,
    // count u32 LE, scale f32 LE, bias f32 LE, id, kind, payload
    if (o + 20 > u8.length) return;
    if (u8[o] !== 0x43 || u8[o + 1] !== 0x4e || u8[o + 2] !== 0x58 || u8[o + 3] !== 0x56)
      return;
    const idLen = u8[o + 5];
    const kindLen = u8[o + 6];
    const fmt = u8[o + 7];
    const n = dv.getUint32(o + 8, true);
    const scale = dv.getFloat32(o + 12, true);
    const bias = dv.getFloat32(o + 16, true);
    let p = o + 20;
    if (p + idLen + kindLen > u8.length) return;
    let id = '';
    for (let i = 0; i < idLen; ++i) id += String.fromCharCode(u8[p++]);
    let kind = '';
    for (let i = 0; i < kindLen; ++i) kind += String.fromCharCode(u8[p++]);
    const bps = fmt === 0 ? 4 : fmt === 1 ? 2 : 1;
    if (n * bps > u8.length - p) return;
    const v = new Float32Array(n);
    if (fmt === 0) {
      // f32 verbatim — typed-array views need 4-byte alignment
      const byteOff = u8.byteOffset + p;
      if (byteOff % 4 === 0) v.set(new Float32Array(u8.buffer, byteOff, n));
      else v.set(new Float32Array(u8.slice(p, p + n * 4).buffer, 0, n));
    } else if (fmt === 1) {
      // i16 quantized: plain = stored * scale + bias (2-byte alignment)
      const byteOff = u8.byteOffset + p;
      const src =
        byteOff % 2 === 0
          ? new Int16Array(u8.buffer, byteOff, n)
          : new Int16Array(u8.slice(p, p + n * 2).buffer, 0, n);
      for (let i = 0; i < n; ++i) v[i] = src[i] * scale + bias;
    } else if (fmt === 3) {
      const src = new Int8Array(u8.buffer, u8.byteOffset + p, n);
      for (let i = 0; i < n; ++i) v[i] = src[i] * scale + bias;
    } else {
      for (let i = 0; i < n; ++i) v[i] = u8[p + i] * scale + bias;
    }
    p += n * bps;
    o = p;
    deliverToUi({ t: 'viz', id, kind: kind as VizKind, v });
  }
}

function installAuxBridgeShim(): void {
  window.__auxbridge = {
    _recv: (msg: unknown) => {
      const m = msg as { type?: string; values?: Record<string, number> };
      if (m?.type === 'params' && m.values) {
        for (const [idStr, v] of Object.entries(m.values)) {
          const id = Number(idStr);
          if (Number.isFinite(id) && typeof v === 'number' && Number.isFinite(v))
            deliverToUi({ t: 'param', id, v });
        }
      }
    },
    _recvBin: (b64: string) => {
      try {
        decodeCnxb(b64);
      } catch (e) {
        console.warn('[calfNXT mac] viz batch decode failed', e);
      }
    },
  };
}

installAuxBridgeShim();

/** Post to the in-process WKWebView host (WKScriptMessage preserves doubles). */
export function postToHost(msg: calfNXTMsg): void {
  const g = window as unknown as {
    webkit?: { messageHandlers?: { auxHost?: { postMessage(m: unknown): void } } };
  };
  const handler = g.webkit?.messageHandlers?.auxHost;
  if (handler) handler.postMessage(msg);
  else console.warn('[calfNXT mac] no native host (browser preview):', msg);
}

/** Install host→UI handler and flush messages queued before React mounted. */
export function onHostMessage(handler: (msg: calfNXTMsg) => void): void {
  window.__calfnxtOnHost = (msg) => {
    // Per-tick dump copies only under AUXVST_DEBUG (window.__auxvstDebug).
    if (window.__auxvstDebug && msg?.t === 'viz' && typeof msg.id === 'string' && isVizSamples(msg.v))
      vizDumpBag()[`${msg.id}:${msg.kind}`] = vizSamplesForDump(msg.v);
    handler(msg);
  };
  const q = window.__calfnxtHostQ;
  if (q && q.length) {
    window.__calfnxtHostQ = [];
    for (const msg of q) window.__calfnxtOnHost!(msg);
  }
}
