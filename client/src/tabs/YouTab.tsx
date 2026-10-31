import { me } from '../state/store';
import { Profile } from '../you/Profile';
import { Feed } from '../you/Feed';
import { Archive } from '../notes/Archive';
import { Store } from '../you/Store';
import { FieldManual } from '../guide/Guide';
import { Settings } from '../you/Settings';
import { GuestNote } from '../you/Account';
import '../shell/shell.css';
import '../you/you.css';

export function YouTab() {
  if (!me.value) return null;
  return (
    <div class="panel scroll you-tab">
      <GuestNote />
      <Profile />
      <Archive />
      <Feed />
      <Store />
      <FieldManual />
      <Settings />
    </div>
  );
}
