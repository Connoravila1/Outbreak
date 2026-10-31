import { useState } from 'preact/hooks';
import type { Faction } from '../api';
import { position } from '../location';
import { lensOverride, me, phase, loadCatalog } from '../state/store';
import { Broadcast } from './Broadcast';
import { Locate } from './Locate';
import { Bitten } from './Bitten';
import { SplitLens } from './SplitLens';
import { Callsign } from './Callsign';
import { Kit } from './Kit';
import { RecoveryCode } from './Recovery';
import { Briefing } from './Briefing';
import { Recover } from './Recover';
import { requestNotifyPermission, scheduleDailyReset } from '../native/notify';
import './onboarding.css';

/** After onboarding: the one moment we ask to send alerts. */
function askNotify() { void requestNotifyPermission().then((ok) => { if (ok) void scheduleDailyReset(); }); }

type Step = 'broadcast' | 'recover' | 'locate' | 'bitten' | 'split' | 'callsign' | 'kit' | 'recovery' | 'briefing';

/** First launch: broadcast, permission, the bite, the choosing, identity, kit, briefing. */
export function Onboarding() {
  // An account with no faction yet (quit mid-way) skips the cold open.
  const [step, setStep] = useState<Step>(me.value && !me.value.faction ? 'locate' : 'broadcast');
  const [chosen, setChosen] = useState<Faction | null>(null);
  const accountExists = !!me.value;

  const go = (s: Step) => setStep(s);
  const chose = (f: Faction) => { setChosen(f); lensOverride.value = f === 'human' ? 'survey' : 'heat'; go('callsign'); };

  const p = position.value;
  switch (step) {
    case 'broadcast': return <Broadcast onDone={() => go('locate')} onRecover={() => go('recover')} />;
    case 'recover': return <Recover onBack={() => go('broadcast')} onRecovered={(hasFaction) => { if (hasFaction) { phase.value = 'app'; askNotify(); } else go('locate'); }} />;
    case 'locate': return <Locate onDone={() => go(accountExists ? 'split' : 'bitten')} />;
    case 'bitten': return <Bitten onDone={() => go('split')} />;
    case 'split': return p ? <SplitLens center={p} onChosen={chose} /> : <Locate onDone={() => go('split')} />;
    case 'callsign': return <Callsign faction={chosen ?? 'human'} accountExists={accountExists} onDone={() => { void loadCatalog().then(() => go('kit')); }} />;
    case 'kit': return <Kit onDone={() => go('recovery')} />;
    case 'recovery': return <RecoveryCode onDone={() => go('briefing')} />;
    case 'briefing': return <Briefing onDone={() => { lensOverride.value = null; phase.value = 'app'; askNotify(); }} />;
  }
}
