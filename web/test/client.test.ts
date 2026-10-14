import { afterEach, describe, expect, it, vi } from 'vitest';
import { ApiError, backoffMs, DEFAULT_PORT, LocalApi, loadPort, parsePort, savePort } from '../src/api/client';

function recorder(respond: (url: string) => Response | Promise<Response>) {
  const calls: string[] = [];
  const fetchImpl = (async (url: string) => { calls.push(url); return await respond(url); }) as unknown as typeof fetch;
  return { calls, fetchImpl };
}

describe('LocalApi', () => {
  it('reads from 127.0.0.1 on the given port', async () => {
    const { calls, fetchImpl } = recorder(() => Response.json({ battle: null }));
    const api = new LocalApi(5000, fetchImpl);
    expect(api.baseUrl).toBe('http://127.0.0.1:5000');
    await api.trainer().catch(() => undefined);
    await api.battle();
    await api.boards().catch(() => undefined);
    expect(calls).toEqual(['http://127.0.0.1:5000/v1/trainer', 'http://127.0.0.1:5000/v1/battle', 'http://127.0.0.1:5000/v1/boards']);
  });

  it('maps a 403 origin_not_paired body to an unpaired status', async () => {
    const { fetchImpl } = recorder(() => Response.json({ error: 'origin_not_paired', message: 'approve it' }, { status: 403 }));
    const err = await new LocalApi(DEFAULT_PORT, fetchImpl).trainer().catch((e: unknown) => e);
    expect(err).toBeInstanceOf(ApiError);
    expect(err).toMatchObject({ status: 403, code: 'origin_not_paired' });
    expect(LocalApi.statusOf(err)).toEqual({ kind: 'unpaired' });
  });

  it('maps a network failure to unreachable, naming the port', async () => {
    const api = new LocalApi(4711, (async () => { throw new TypeError('Failed to fetch'); }) as typeof fetch);
    const err = await api.trainer().catch((e: unknown) => e);
    expect(err).toMatchObject({ status: 0, code: 'unreachable', message: expect.stringContaining('4711') });
    expect(LocalApi.statusOf(err).kind).toBe('unreachable');
  });

  it('keeps other error bodies, and survives a non-JSON error page', async () => {
    const mis = recorder(() => Response.json({ error: 'misdirected', message: 'wrong host' }, { status: 421 }));
    const err = await new LocalApi(1, mis.fetchImpl).trainer().catch((e: unknown) => e);
    expect(err).toMatchObject({ status: 421, code: 'misdirected' });
    expect(LocalApi.statusOf(err)).toEqual({ kind: 'error', message: 'wrong host' });
    const html = recorder(() => new Response('<html>nope</html>', { status: 502, statusText: 'Bad Gateway' }));
    await expect(new LocalApi(1, html.fetchImpl).trainer()).rejects.toMatchObject({ status: 502, code: 'http_502' });
  });
});

describe('events', () => {
  class FakeSource {
    static all: FakeSource[] = [];
    listeners = new Map<string, (e: { data: string }) => void>();
    onopen: (() => void) | null = null;
    onerror: (() => void) | null = null;
    closed = false;
    constructor(readonly url: string) { FakeSource.all.push(this); }
    addEventListener(name: string, fn: (e: { data: string }) => void) { this.listeners.set(name, fn); }
    close() { this.closed = true; }
  }
  afterEach(() => { FakeSource.all = []; vi.useRealTimers(); });

  it('forwards events as parsed JSON and reports live once open', () => {
    const events: [string, unknown][] = [];
    const statuses: string[] = [];
    const api = new LocalApi(1, (async () => Response.json({})) as typeof fetch, FakeSource as unknown as typeof EventSource);
    const stop = api.events({ onEvent: (n, d) => events.push([n, d]), onStatus: (s) => statuses.push(s.kind) });
    const es = FakeSource.all[0]!;
    expect(es.url).toBe('http://127.0.0.1:1/v1/events');
    es.onopen?.();
    es.listeners.get('battle')!({ data: '{"battle":null}' });
    es.listeners.get('boards')!({ data: 'not json' });
    expect(events).toEqual([['battle', { battle: null }]]);
    expect(statuses).toEqual(['connecting', 'live']);
    stop();
    expect(es.closed).toBe(true);
  });

  it('tells a pairing refusal from a dead port after a stream error, and retries', async () => {
    vi.useFakeTimers();
    let paired = false;
    const statuses: string[] = [];
    const fetchImpl = (async () => paired
      ? Response.json({ trainer: {} })
      : Response.json({ error: 'origin_not_paired', message: '' }, { status: 403 })) as unknown as typeof fetch;
    const api = new LocalApi(1, fetchImpl, FakeSource as unknown as typeof EventSource);
    const stop = api.events({ onEvent: () => undefined, onStatus: (s) => statuses.push(s.kind) });
    FakeSource.all[0]!.onerror?.();
    await vi.advanceTimersByTimeAsync(0);
    expect(statuses.at(-1)).toBe('unpaired');
    paired = true;
    await vi.advanceTimersByTimeAsync(3000);
    expect(FakeSource.all).toHaveLength(2);
    stop();
  });
});

describe('backoff', () => {
  it('doubles from 1 s up to 15 s', () => {
    expect([0, 1, 2, 3, 4, 5, 9].map(backoffMs)).toEqual([1000, 2000, 4000, 8000, 15000, 15000, 15000]);
  });
});

describe('port', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('accepts only whole ports between 1 and 65535', () => {
    expect(parsePort(' 47323 ')).toBe(47323);
    expect(parsePort(8080)).toBe(8080);
    for (const bad of ['', '0', '65536', '12.5', 'abc', '-1', undefined, null]) expect(parsePort(bad)).toBeUndefined();
  });

  it('loads the saved port, falls back to 47323, and survives blocked storage', () => {
    const data = new Map<string, string>();
    vi.stubGlobal('localStorage', { getItem: (k: string) => data.get(k) ?? null, setItem: (k: string, v: string) => { data.set(k, v); } });
    expect(loadPort()).toBe(DEFAULT_PORT);
    savePort(5555);
    expect(loadPort()).toBe(5555);
    data.set('ptb.port', 'junk');
    expect(loadPort()).toBe(DEFAULT_PORT);
    vi.stubGlobal('localStorage', { getItem: () => { throw new Error('blocked'); }, setItem: () => { throw new Error('blocked'); } });
    expect(loadPort()).toBe(DEFAULT_PORT);
    expect(() => savePort(1234)).not.toThrow();
  });
});
