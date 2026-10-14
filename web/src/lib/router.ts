import { createSignal } from 'solid-js';
import { parseRoute } from './routes';

export { href, type Route } from './routes';

const [route, setRoute] = createSignal(parseRoute(location.hash));
addEventListener('hashchange', () => setRoute(parseRoute(location.hash)));
export { route };
