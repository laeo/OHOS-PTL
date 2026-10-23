// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 OpenHarmony PC Image Contributors

// One terminal tab = one independent PTY session.
//
// Each Session owns its own TCP connection to the on-device PTY daemon
// (ohosptyd, 127.0.0.1:7788).  The daemon forks a fresh pseudo-terminal per
// accepted connection, so every tab is a fully isolated shell with its own
// working directory, job control and scrollback.
//
// Wire protocol (unchanged, matches ohosptyd.c):
//   client -> daemon:  u8 type | u16 len (LE) | payload
//       type 0 : terminal input bytes
//       type 1 : window size, cols(LE16) rows(LE16) xpix(LE16) ypix(LE16)
//       type 2 : kill the foreground process group
//   daemon -> client:  raw terminal output bytes

import { socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { Terminal } from './terminal';

const DOMAIN: number = 0x0011;
const TAG: string = 'OHOSTerm';
export const HOST: string = '127.0.0.1';
export const PORT: number = 7788;

export class Session {
  id: number;
  term: Terminal;
  title: string = 'Shell';
  tcp: socket.TCPSocket | undefined = undefined;
  connected: boolean = false;
  private connTimer: number = -1;
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private onDirty: () => void;
  private onTitle: () => void;
  private onExit: () => void;
  // set once the tab is closed on purpose, so the socket close that follows is
  // not mistaken for the shell itself exiting (which closes the tab).
  private closingOnPurpose: boolean = false;

  constructor(id: number, cols: number, rows: number,
    onDirty: () => void, onTitle: () => void, onExit: () => void) {
    this.id = id;
    this.onDirty = onDirty;
    this.onTitle = onTitle;
    this.onExit = onExit;
    this.term = new Terminal(cols, rows);
    this.term.respond = (s: string): void => { this.sendInputStr(s); };
    this.term.onTitle = (): void => {
      if (this.term.title.length > 0) { this.title = this.term.title; }
      this.onTitle();
    };
  }

  sendFrame(type: number, payload: Uint8Array): void {
    const t: socket.TCPSocket | undefined = this.tcp;
    if (!t || !this.connected) { return; }
    const buf = new ArrayBuffer(3 + payload.length);
    const v = new Uint8Array(buf);
    v[0] = type;
    v[1] = payload.length & 0xff;
    v[2] = (payload.length >> 8) & 0xff;
    v.set(payload, 3);
    t.send({ data: buf }).catch((e: BusinessError): void => {});
  }

  sendInputStr(s: string): void {
    if (s.length === 0) { return; }
    this.term.scrollToBottom();
    this.sendFrame(0, this.encoder.encodeInto(s));
  }

  sendResize(cols: number, rows: number): void {
    const p = new Uint8Array(8);
    p[0] = cols & 0xff;
    p[1] = (cols >> 8) & 0xff;
    p[2] = rows & 0xff;
    p[3] = (rows >> 8) & 0xff;
    this.sendFrame(1, p);
  }

  connect(): void {
    if (this.connected) { return; }
    const tcp: socket.TCPSocket = socket.constructTCPSocketInstance();
    this.tcp = tcp;
    tcp.on('message', (value: socket.SocketMessageInfo): void => {
      const u8 = new Uint8Array(value.message as ArrayBuffer);
      try {
        const s = this.decoder.decodeToString(u8, { stream: true });
        const atBottom = this.term.viewOffset === 0;
        this.term.write(s);
        if (atBottom) { this.term.scrollToBottom(); }
        this.onDirty();
      } catch (e) {
        hilog.error(DOMAIN, TAG, 'decode fail');
      }
    });
    tcp.on('close', (): void => {
      const was = this.connected;
      this.connected = false;
      if (this.closingOnPurpose) { return; }
      if (was) {
        // The shell process is gone (the user typed `exit` / `logout`, or the
        // sandbox died with it).  This tab has nothing left to talk to.
        this.onExit();
        return;
      }
      this.scheduleReconnect();
    });
    tcp.on('error', (e: BusinessError): void => {
      const was = this.connected;
      this.connected = false;
      if (this.closingOnPurpose) { return; }
      if (was) {
        this.onExit();
        return;
      }
      this.scheduleReconnect();
    });
    tcp.bind({ address: '0.0.0.0', port: 0, family: 1 })
      .then((): Promise<void> => {
        return tcp.connect({ address: { address: HOST, port: PORT, family: 1 }, timeout: 6000 });
      })
      .then((): void => {
        this.connected = true;
        hilog.info(DOMAIN, TAG, 'session %{public}d connected', this.id);
        this.sendResize(this.term.cols, this.term.rows);
        this.onDirty();
      })
      .catch((e: BusinessError): void => {
        this.connected = false;
        this.scheduleReconnect();
      });
  }

  private scheduleReconnect(): void {
    if (this.connTimer >= 0) { return; }
    this.connTimer = setInterval((): void => {
      if (this.connected) {
        clearInterval(this.connTimer);
        this.connTimer = -1;
        return;
      }
      clearInterval(this.connTimer);
      this.connTimer = -1;
      this.connect();
    }, 1500);
  }

  close(): void {
    this.closingOnPurpose = true;
    if (this.connTimer >= 0) {
      clearInterval(this.connTimer);
      this.connTimer = -1;
    }
    const t: socket.TCPSocket | undefined = this.tcp;
    if (t) {
      try { t.close(); } catch (e) { /* ignore */ }
      this.tcp = undefined;
    }
    this.connected = false;
  }
}
