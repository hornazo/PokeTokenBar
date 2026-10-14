import { href } from '../lib/router';

/** A shared invite link: hands the code to the app through its deep link. Needs no data from the app. */
export function Join(props: { code: string }) {
  const deepLink = () => `poketokenbar://boards/join?code=${encodeURIComponent(props.code)}`;
  return (
    <div class="panel">
      <div class="eyebrow">Board invite</div>
      <h1>Join a board</h1>
      <p>Invite code</p>
      <p class="join-code"><code>{props.code}</code></p>
      <div class="actions">
        <a class="btn primary" href={deepLink()}>Join in PokeTokenBar</a>
        <a class="btn ghost" href={href('boards')}>Your boards</a>
      </div>
      <p class="note">PokeTokenBar opens and asks you to confirm before it joins. You need the app installed on this Mac.</p>
    </div>
  );
}
