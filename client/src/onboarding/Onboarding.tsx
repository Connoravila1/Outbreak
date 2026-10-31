import { useState } from 'preact/hooks';
import type { Faction } from '../api';
import { position } from '../location';
import { lensOverride, me, phase, loadCatalog } from '../state/store';
import { Broadcast } from './Broadcast';
import { Locate } from './Locate';
import { Age, AgeRefusal } from './Age';
import { Terms } from './Terms';
import { SafetyStep } from '../safety/Safety';
import { ageBlocked } from '../safety/age';
import { Bitten } from './Bitten';
import { SplitLens } from './SplitLens';
import { Commit } from './Commit';
import { Save } from './Save';
import { SignIn } from './SignIn';
import { Callsign } from './Callsign';
import { Kit } from './Kit';
import { Creator } from '../avatar/Creator';
import { Briefing } from './Briefing';
import type { Done } from '../auth/ProviderButtons';
import { requestNotifyPermission, scheduleDailyReset } from '../native/notify';
import './onboarding.css';

/** After onboarding: the one moment we ask to send alerts. */
function askNotify() { void requestNotifyPermission().then((ok) => { if (ok) void scheduleDailyReset(); }); }

type Step = 'broadcast' | 'age' | 'refused' | 'terms' | 'safety' | 'signin' | 'locate' | 'bitten' | 'split' | 'commit' | 'save' | 'callsign' | 'avatar' | 'kit' | 'briefing';

/** Where an account that already exists on the server picks up. */
function resumeStep(): Step {
  const m = me.value;
  if (!m) return 'age';
  if (m.faction && m.must_rename) return 'callsign';
  if (!m.faction) return 'locate';
  return m.account.guest ? 'save' : 'callsign';
}

/** First launch: the checkpoint (age, terms) so the cold open runs unbroken, the broadcast, the safety card, permission, the bite, the choosing, saving the survivor, identity, kit, briefing. */
export function Onboarding() {
  // An account quit mid-way skips the cold open.
  const [step, setStep] = useState<Step>(() => (!me.value && ageBlocked() ? 'refused' : resumeStep()));
  const [chosen, setChosen] = useState<Faction | null>(me.value?.faction ?? null);
  // Resumed accounts have seen the bite already.
  const [skipBite] = useState(!!me.value);
  // A moderator reset this callsign: choose again, then straight back into the game.
  const [renaming] = useState(!!me.value?.must_rename);

  const go = (s: Step) => setStep(s);
  const chose = (f: Faction) => { setChosen(f); lensOverride.value = f === 'human' ? 'survey' : 'heat'; go('commit'); };
  const enterApp = () => { lensOverride.value = null; phase.value = 'app'; askNotify(); };
  /** A sign-in succeeded: continue from wherever that character stands. */
  const signedIn = (d: Done) => {
    const m = d.me;
    if (m.faction && m.callsign && !m.must_rename) { void loadCatalog(); enterApp(); } else if (m.faction) { setChosen(m.faction); go('callsign'); } else go('locate');
  };

  const p = position.value;
  switch (step) {
    case 'broadcast': return <Broadcast onDone={() => go('safety')} onSignIn={() => go('signin')} />;
    case 'age': return <Age onPass={() => go('terms')} onRefuse={() => go('refused')} />;
    case 'refused': return <AgeRefusal />;
    case 'terms': return <Terms onDone={() => go('broadcast')} />;
    case 'safety': return <SafetyStep onDone={() => go('locate')} />;
    case 'signin': return <SignIn onBack={() => go('broadcast')} onDone={signedIn} />;
    case 'locate': return <Locate onDone={() => go(skipBite ? 'split' : 'bitten')} />;
    case 'bitten': return <Bitten onDone={() => go('split')} />;
    case 'split': return p ? <SplitLens center={p} onChosen={chose} /> : <Locate onDone={() => go('split')} />;
    case 'commit': return <Commit faction={chosen ?? 'human'} onDone={() => go(me.value?.account.guest ? 'save' : 'callsign')} />;
    case 'save': return <Save onDone={signedIn} onGuest={() => go('callsign')} />;
    case 'callsign': return <Callsign faction={chosen ?? 'human'} renaming={renaming} onDone={() => { void loadCatalog().then(() => (renaming ? enterApp() : go('avatar'))); }} />;
    case 'avatar': return <div class="ob-screen"><div class="ob-card wide"><Creator faction={chosen ?? 'human'} level={1} initial={me.value?.avatar} later onDone={() => go('kit')} /></div></div>;
    case 'kit': return <Kit onDone={() => go('briefing')} />;
    case 'briefing': return <Briefing onDone={enterApp} />;
  }
}
