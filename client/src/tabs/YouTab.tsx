import { me } from '../state/store';
import { Profile } from '../you/Profile';
import { Feed } from '../you/Feed';
import { Store } from '../you/Store';
import { Settings } from '../you/Settings';
import '../shell/shell.css';
import '../you/you.css';

export function YouTab() {
  if (!me.value) return null;
  return (
    <div class="panel scroll you-tab">
      <Profile />
      <Feed />
      <Store />
      <Settings />
    </div>
  );
}
