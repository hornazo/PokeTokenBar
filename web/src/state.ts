import { createRoot, createSignal } from 'solid-js';
import { LocalApi, loadPort, savePort, type Connection, type EventName } from './api/client';
import { applyEvent, isBattleLive, type LiveData } from './live';

/** One live store, fed by the app's event stream. */
export const app = createRoot(() => {
  const [port, setPortRaw] = createSignal(loadPort());
  const [data, setData] = createSignal<LiveData>({});
  const [status, setStatus] = createSignal<Connection>({ kind: 'connecting' });
  let stop: (() => void) | undefined;

  const connect = () => {
    stop?.();
    const api = new LocalApi(port());
    stop = api.events({
      onEvent: (name: EventName, payload: unknown) => setData((d) => applyEvent(d, name, payload)),
      onStatus: setStatus,
    });
  };
  connect();

  return {
    port,
    /** Saves the port and reconnects; the same port just retries now. */
    setPort: (next: number) => {
      if (next !== port()) {
        savePort(next);
        setPortRaw(next);
        setData({});
      }
      connect();
    },
    data,
    status,
    battleLive: () => isBattleLive(data()),
  };
});
