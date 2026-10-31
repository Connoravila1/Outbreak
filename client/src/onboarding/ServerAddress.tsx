import { useState } from 'preact/hooks';
import { api, errorMessage, setServerUrl } from '../api';

const clean = (v: string) => {
  const t = v.trim();
  return t && !/^https?:\/\//i.test(t) ? 'http://' + t : t;
};

/** Native first launch with no baked-in server: ask where the game lives, test it, save it. */
export function ServerAddress({ onDone }: { onDone: () => void }) {
  const [url, setUrl] = useState('');
  const [busy, setBusy] = useState(false);
  const [res, setRes] = useState<{ ok: boolean; text: string } | null>(null);

  const test = async () => {
    setBusy(true); setRes(null);
    try {
      const h = await api.health(clean(url));
      setRes(h.ok ? { ok: true, text: `Connected. Server ${h.version}, ${h.players_online} online.` } : { ok: false, text: 'The server answered but says it is not ok.' });
    } catch (e) { setRes({ ok: false, text: errorMessage(e) }); } finally { setBusy(false); }
  };
  const save = () => { setServerUrl(clean(url)); onDone(); };

  return (
    <div class="ob-screen server">
      <form class="ob-card" onSubmit={(e) => { e.preventDefault(); if (res?.ok) save(); else void test(); }} noValidate>
        <p class="eyebrow">First launch</p>
        <h1 class="ob-h">Server address</h1>
        <p>Where is the Outbreak server? For example <span class="num">https://play.example.com</span> or a LAN address like <span class="num">http://192.168.1.20:8080</span>.</p>
        <input class="field big" value={url} autoFocus inputMode="url" autocomplete="off" autocapitalize="off" spellcheck={false} placeholder="https://"
          onInput={(e) => { setUrl((e.target as HTMLInputElement).value); setRes(null); }} />
        {res && <p class={'ob-hint ' + (res.ok ? '' : 'bad')} role={res.ok ? 'status' : 'alert'}>{res.text}</p>}
        <div class="ob-actions">
          <button class="btn primary block" type="submit" disabled={busy || !url.trim()}>{busy ? '…' : res?.ok ? 'Continue' : 'Test connection'}</button>
          {!res?.ok && <button class="btn block" type="button" disabled={!url.trim()} onClick={save}>Save without testing</button>}
        </div>
      </form>
    </div>
  );
}
