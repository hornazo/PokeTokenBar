import type { ApiErrorBody, BattleResponse, BoardsResponse, TrainerResponse } from './types';

export const DEFAULT_PORT = 47323;
const PORT_KEY = 'ptb.port';

export class ApiError extends Error {
  constructor(readonly status: number, readonly code: string, message: string) {
    super(message);
  }
}

/** A TCP port from user input, or undefined when it isn't one. */
export function parsePort(input: string | number | null | undefined): number | undefined {
  const text = String(input ?? '').trim();
  if (!/^\d{1,5}$/.test(text)) return undefined;
  const port = Number(text);
  return port >= 1 && port <= 65535 ? port : undefined;
}

/** The saved port, else the build-time default, else 47323. */
export function loadPort(): number {
  let saved: string | null = null;
  try { saved = localStorage.getItem(PORT_KEY); } catch { /* storage blocked: use the default */ }
  return parsePort(saved) ?? parsePort(import.meta.env.VITE_PTB_LOCAL_PORT as string | undefined) ?? DEFAULT_PORT;
}

export function savePort(port: number): void {
  try { localStorage.setItem(PORT_KEY, String(port)); } catch { /* storage blocked: the port lasts for this visit only */ }
}

export type EventName = 'trainer' | 'battle' | 'boards';
export const EVENT_NAMES: readonly EventName[] = ['trainer', 'battle', 'boards'];

/** `unpaired`: the app is there but hasn't approved this page yet. `unreachable`: nothing answered. */
export type ConnectionKind = 'connecting' | 'live' | 'unpaired' | 'unreachable' | 'error';
export interface Connection { kind: ConnectionKind; message?: string }

export interface EventHandlers {
  onEvent(name: EventName, data: unknown): void;
  onStatus(status: Connection): void;
}

const RETRY_MS = { unpaired: 3000, min: 1000, max: 15000 };

/** Reconnect delay after the nth failed attempt in a row: 1 s doubling up to 15 s. */
export function backoffMs(attempt: number): number {
  return Math.min(RETRY_MS.max, RETRY_MS.min * 2 ** Math.max(0, attempt));
}

/** Read-only client for the app's local API. */
export class LocalApi {
  readonly baseUrl: string;

  constructor(
    readonly port: number,
    private readonly fetchImpl: typeof fetch = (...args) => fetch(...args),
    private readonly eventSourceImpl: typeof EventSource | undefined = typeof EventSource === 'undefined' ? undefined : EventSource,
  ) {
    this.baseUrl = `http://127.0.0.1:${port}`;
  }

  url(path: string): string {
    return this.baseUrl + path;
  }

  async request<T>(path: string): Promise<T> {
    let res: Response;
    try {
      res = await this.fetchImpl(this.url(path), { headers: { accept: 'application/json' } });
    } catch {
      throw new ApiError(0, 'unreachable', `Can’t reach PokeTokenBar on port ${this.port}.`);
    }
    const text = await res.text();
    let data: unknown;
    try { data = text ? JSON.parse(text) : undefined; } catch { data = undefined; }
    if (!res.ok) {
      const err = data as Partial<ApiErrorBody> | undefined;
      throw new ApiError(res.status, err?.error ?? `http_${res.status}`, err?.message ?? res.statusText);
    }
    return data as T;
  }

  trainer() { return this.request<TrainerResponse>('/v1/trainer'); }
  battle() { return this.request<BattleResponse>('/v1/battle'); }
  boards() { return this.request<BoardsResponse>('/v1/boards'); }

  /** The connection state an error stands for. */
  static statusOf(err: unknown): Connection {
    if (err instanceof ApiError) {
      if (err.code === 'origin_not_paired') return { kind: 'unpaired' };
      if (err.code === 'unreachable') return { kind: 'unreachable', message: err.message };
      return { kind: 'error', message: err.message };
    }
    return { kind: 'error', message: err instanceof Error ? err.message : String(err) };
  }

  /**
   * Subscribes to `/v1/events`, reconnecting with backoff. An EventSource can't tell a 403 from a dead
   * port, so after every error a plain fetch to `/v1/trainer` says which it was. Returns the stop function.
   */
  events(handlers: EventHandlers): () => void {
    let stopped = false;
    let source: EventSource | undefined;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let attempt = 0;

    const retry = (ms: number) => {
      if (!stopped) timer = setTimeout(connect, ms);
    };

    const failed = async () => {
      source?.close();
      source = undefined;
      try {
        // Reachable and approved: the stream itself broke, so refresh by hand until it's back.
        const trainer = await this.trainer();
        if (stopped) return;
        handlers.onEvent('trainer', trainer);
        handlers.onStatus({ kind: 'connecting' });
        retry(backoffMs(attempt++));
      } catch (err) {
        if (stopped) return;
        const status = LocalApi.statusOf(err);
        handlers.onStatus(status);
        retry(status.kind === 'unpaired' ? RETRY_MS.unpaired : backoffMs(attempt++));
      }
    };

    const connect = () => {
      if (stopped) return;
      if (!this.eventSourceImpl) { void failed(); return; }
      handlers.onStatus({ kind: 'connecting' });
      const es = new this.eventSourceImpl(this.url('/v1/events'));
      source = es;
      es.onopen = () => { attempt = 0; handlers.onStatus({ kind: 'live' }); };
      es.onerror = () => { if (source === es) void failed(); };
      for (const name of EVENT_NAMES) {
        es.addEventListener(name, (e) => {
          try { handlers.onEvent(name, JSON.parse((e as MessageEvent<string>).data)); } catch { /* malformed event: skip it */ }
        });
      }
    };

    connect();
    return () => { stopped = true; clearTimeout(timer); source?.close(); };
  }
}
