import { useState } from 'preact/hooks';
import { say } from '../ui/voice';
import { birthProblem, blockAge, MONTHS, oldEnough } from '../safety/age';

/** The checkpoint after the broadcast: month and year of birth, asked plainly. The answer stays on the phone. */
export function Age({ onPass, onRefuse }: { onPass: () => void; onRefuse: () => void }) {
  const [month, setMonth] = useState(0);
  const [year, setYear] = useState('');
  const [err, setErr] = useState<string | null>(null);

  const submit = (e: Event) => {
    e.preventDefault();
    const y = Number(year);
    const bad = birthProblem(y, month);
    if (bad) { setErr(bad); return; }
    if (oldEnough(y, month)) { onPass(); return; }
    blockAge();
    onRefuse();
  };

  return (
    <div class="ob-screen age">
      <form class="ob-card" onSubmit={submit} noValidate>
        <p class="eyebrow">{say('Checkpoint', 'the gate')}</p>
        <h1 class="ob-h">{say('Your papers.', 'who are you.')}</h1>
        <p>{say('Month and year of birth. It is checked on this phone, once. It is not sent anywhere and nobody keeps it.', 'month and year of birth. checked here, once. not sent. not kept.')}</p>
        <div class="dob">
          <label class="sr-only" for="dob-m">Month</label>
          <select id="dob-m" class="field" value={month} onChange={(e) => { setMonth(Number((e.target as HTMLSelectElement).value)); setErr(null); }}>
            <option value={0}>Month</option>
            {MONTHS.map((m, i) => <option key={m} value={i + 1}>{m}</option>)}
          </select>
          <label class="sr-only" for="dob-y">Year</label>
          <input id="dob-y" class="field" value={year} inputMode="numeric" maxLength={4} placeholder="Year" autocomplete="off"
            onInput={(e) => { setYear((e.target as HTMLInputElement).value.replace(/\D/g, '')); setErr(null); }} />
        </div>
        {err && <p class="ob-error" role="alert">{err}</p>}
        <button class="btn primary block" type="submit" disabled={!month || year.length !== 4}>{say('Continue', 'continue')}</button>
      </form>
    </div>
  );
}

/** Shown instead of everything else for a day after someone under the age was turned away. */
export function AgeRefusal() {
  return (
    <div class="ob-screen age">
      <div class="ob-card">
        <p class="eyebrow">{say('Not this time', 'not yet')}</p>
        <h1 class="ob-h">{say('Come back when you are older.', 'come back when you are older.')}</h1>
        <p>{say('Outbreak is for older players, so we cannot let you in yet. Nothing was sent or saved. Thank you for asking, and take care out there.', 'this place is for older ones. nothing was sent. nothing was kept. be well. come back later.')}</p>
      </div>
    </div>
  );
}
