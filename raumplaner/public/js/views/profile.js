import { post, put } from '../api.js';
import { state } from '../state.js';
import { copyToClipboard, field, h, icon, setBusy, toast, toastError } from '../ui.js';

const REMINDERS = [
  [0, 'Keine Erinnerung'],
  [5, '5 Minuten vorher'],
  [10, '10 Minuten vorher'],
  [15, '15 Minuten vorher'],
  [30, '30 Minuten vorher'],
  [60, '1 Stunde vorher'],
  [120, '2 Stunden vorher'],
  [1440, '1 Tag vorher'],
];

function desktopState() {
  if (!('Notification' in window)) return 'unsupported';
  let off = false;
  try {
    off = localStorage.getItem('rp.desktop') === 'off';
  } catch {
    /* egal */
  }
  if (Notification.permission === 'granted') return off ? 'off' : 'on';
  return Notification.permission; // 'default' | 'denied'
}

function renderHostedProfile(root) {
  const me = state.me;
  const reminderSel = h('select', { class: 'input', id: 'pf-reminder' }, REMINDERS.map(([v, label]) => h('option', { value: String(v) }, label)));
  reminderSel.value = String(me.reminderMinutes);
  reminderSel.addEventListener('change', async () => {
    try {
      const res = await put('/api/me', { reminderMinutes: Number(reminderSel.value) });
      state.me = res.user;
      toast('Gespeichert', { type: 'success', timeout: 2500 });
    } catch (err) {
      toastError(err);
    }
  });
  const testBtn = h(
    'button',
    {
      class: 'btn',
      type: 'button',
      onClick: async () => {
        setBusy(testBtn, true);
        try {
          await post('/api/me/test-notification');
          toast('Test verschickt', { type: 'success', body: 'Gleich erscheint sie oben rechts in der Glocke – auch auf deinen anderen Geräten.' });
        } catch (err) {
          toastError(err);
        } finally {
          setBusy(testBtn, false);
        }
      },
    },
    icon('bell'),
    'Test-Benachrichtigung senden',
  );
  const role = !state.config.canWrite ? 'Nur Ansicht' : me.role === 'admin' ? 'Administration' : 'Mitarbeiter/in';
  root.append(
    h('div', { class: 'page-head' }, h('div', null, h('h1', null, 'Profil & Benachrichtigungen'), h('p', null, [me.name, me.email, role].filter(Boolean).join(' · ')))),
    h(
      'div',
      { class: 'grid-2' },
      h(
        'div',
        { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, icon('bell'), 'So wirst du benachrichtigt')),
        h(
          'div',
          { class: 'card-body form' },
          h(
            'div',
            { class: 'notice' },
            icon('info'),
            h('div', null, 'In der App: live über die Glocke oben rechts – auf jedem Gerät, auf dem du den Raumplaner öffnest. Was du verpasst, wartet dort auf dich.'),
          ),
          field('Erinnerung vor Terminbeginn', reminderSel, 'Erinnerungen erscheinen, während der Raumplaner geöffnet ist.'),
          h('div', null, testBtn),
          h(
            'p',
            { class: 'hint' },
            'E-Mails mit Kalendereinladung verschickt die selbst betriebene Version des Raumplaners (Anleitung im Projekt unter raumplaner/README.md).',
          ),
        ),
      ),
      h(
        'div',
        { class: 'card' },
        h('div', { class: 'card-head' }, h('h2', null, icon('user'), 'Konto')),
        h(
          'div',
          { class: 'card-body stack-sm' },
          h('p', null, 'Du bist über dein claude.ai-Konto angemeldet – ein eigenes Passwort gibt es hier nicht.'),
          h('p', { class: 'muted small' }, `Deine Rolle: ${role}. Wer buchen und verwalten darf, legt die Person fest, die den Raumplaner in claude.ai teilt.`),
        ),
      ),
    ),
  );
}

export async function renderProfile(root) {
  if (state.hosted) return renderHostedProfile(root);
  const me = state.me;

  // ---------------------------------------------------------------- Benachrichtigungen
  const emailIn = h('input', { type: 'checkbox', checked: me.notifyEmail });
  const reminderSel = h(
    'select',
    { class: 'input' },
    REMINDERS.map(([v, label]) => h('option', { value: String(v) }, label)),
  );
  reminderSel.value = String(me.reminderMinutes);
  const desktopBox = h('div', { class: 'stack-sm' });

  async function savePrefs() {
    try {
      const res = await put('/api/me', { notifyEmail: emailIn.checked, reminderMinutes: Number(reminderSel.value) });
      state.me = res.user;
      toast('Gespeichert', { type: 'success', timeout: 2500 });
    } catch (err) {
      toastError(err);
    }
  }
  emailIn.addEventListener('change', savePrefs);
  reminderSel.addEventListener('change', savePrefs);

  function renderDesktop() {
    const st = desktopState();
    const set = (v) => {
      try {
        localStorage.setItem('rp.desktop', v);
      } catch {
        /* egal */
      }
      renderDesktop();
    };
    let content;
    if (st === 'unsupported') content = h('p', { class: 'muted small' }, 'Dieser Browser unterstützt keine Desktop-Benachrichtigungen.');
    else if (st === 'denied')
      content = h('p', { class: 'muted small' }, 'Desktop-Benachrichtigungen sind im Browser blockiert. Du kannst sie in den Website-Einstellungen des Browsers wieder erlauben.');
    else if (st === 'default')
      content = h(
        'button',
        {
          class: 'btn',
          type: 'button',
          onClick: async () => {
            const result = await Notification.requestPermission();
            if (result === 'granted') {
              set('on');
              new Notification('Desktop-Benachrichtigungen aktiv', { body: 'So sehen Benachrichtigungen des Raumplaners aus.', icon: '/favicon.svg' });
            } else renderDesktop();
          },
        },
        icon('monitor'),
        'Desktop-Benachrichtigungen erlauben',
      );
    else
      content = h(
        'label',
        { class: 'check' },
        h('input', { type: 'checkbox', checked: st === 'on', onChange: (e) => set(e.target.checked ? 'on' : 'off') }),
        h('span', null, 'Desktop-Benachrichtigungen anzeigen, wenn der Raumplaner im Hintergrund geöffnet ist'),
      );
    desktopBox.replaceChildren(content);
  }
  renderDesktop();

  const testBtn = h(
    'button',
    {
      class: 'btn',
      type: 'button',
      onClick: async () => {
        setBusy(testBtn, true);
        try {
          const res = await post('/api/me/test-notification');
          toast('Test verschickt', {
            type: 'success',
            body: res.email ? `Prüfe die Glocke oben rechts und dein Postfach (${me.email}).` : 'Prüfe die Glocke oben rechts. (E-Mail-Versand ist nicht eingerichtet.)',
          });
        } catch (err) {
          toastError(err);
        } finally {
          setBusy(testBtn, false);
        }
      },
    },
    icon('bell'),
    'Test-Benachrichtigung senden',
  );

  // ---------------------------------------------------------------- Kalender-Abo
  const calInput = h('input', { class: 'input mono-input', readonly: true, value: state.calendarUrl, 'aria-label': 'Kalender-Abo-Adresse' });
  const calCard = h(
    'div',
    { class: 'card' },
    h('div', { class: 'card-head' }, h('h2', null, icon('calendar'), 'Kalender-Abo')),
    h(
      'div',
      { class: 'card-body stack-sm' },
      h('p', null, 'Abonniere deine Raumbuchungen in Outlook, Google Kalender oder Apple Kalender. Neue und geänderte Termine erscheinen dort automatisch.'),
      h(
        'div',
        { class: 'copy-field' },
        calInput,
        h('button', { class: 'btn', type: 'button', onClick: () => copyToClipboard(calInput.value) }, icon('copy'), 'Kopieren'),
      ),
      h(
        'p',
        { class: 'hint' },
        'Outlook: Kalender → „Kalender hinzufügen“ → „Aus dem Internet abonnieren“ und die Adresse einfügen. Die Adresse ist persönlich – gib sie nicht weiter.',
      ),
      h(
        'div',
        null,
        h(
          'button',
          {
            class: 'btn btn-ghost btn-sm',
            type: 'button',
            onClick: async () => {
              try {
                const res = await post('/api/me/calendar-token');
                state.calendarUrl = res.calendarUrl;
                calInput.value = res.calendarUrl;
                toast('Neue Adresse erstellt', { type: 'success', body: 'Die alte Adresse funktioniert ab sofort nicht mehr.' });
              } catch (err) {
                toastError(err);
              }
            },
          },
          icon('refresh'),
          'Neue Adresse erzeugen',
        ),
      ),
    ),
  );

  // ---------------------------------------------------------------- Konto
  const nameIn = h('input', { class: 'input', value: me.name, autocomplete: 'name' });
  const saveName = h(
    'button',
    {
      class: 'btn',
      type: 'button',
      onClick: async () => {
        try {
          const res = await put('/api/me', { name: nameIn.value });
          state.me = res.user;
          toast('Name gespeichert', { type: 'success', timeout: 2500 });
        } catch (err) {
          toastError(err);
        }
      },
    },
    'Speichern',
  );
  const curPw = h('input', { class: 'input', type: 'password', autocomplete: 'current-password' });
  const newPw = h('input', { class: 'input', type: 'password', autocomplete: 'new-password', minlength: 8 });
  const pwErr = h('div', { class: 'form-error', role: 'alert' });
  const pwForm = h(
    'form',
    {
      class: 'form',
      onSubmit: async (e) => {
        e.preventDefault();
        pwErr.textContent = '';
        try {
          await put('/api/me/password', { currentPassword: curPw.value, newPassword: newPw.value });
          curPw.value = '';
          newPw.value = '';
          toast('Passwort geändert', { type: 'success', body: 'Andere Sitzungen wurden abgemeldet.' });
        } catch (err) {
          pwErr.textContent = err.message;
        }
      },
    },
    field('Aktuelles Passwort', curPw),
    field('Neues Passwort', newPw, 'Mindestens 8 Zeichen.'),
    pwErr,
    h('div', null, h('button', { class: 'btn', type: 'submit' }, 'Passwort ändern')),
  );

  root.append(
    h('div', { class: 'page-head' }, h('div', null, h('h1', null, 'Profil & Benachrichtigungen'), h('p', null, `${me.name} · ${me.email}${me.role === 'admin' ? ' · Administration' : ''}`))),
    h(
      'div',
      { class: 'grid-2' },
      h(
        'div',
        { class: 'stack' },
        h(
          'div',
          { class: 'card' },
          h('div', { class: 'card-head' }, h('h2', null, icon('bell'), 'Wie möchtest du benachrichtigt werden?')),
          h(
            'div',
            { class: 'card-body form' },
            h('div', { class: 'notice' }, icon('info'), h('div', null, 'In der App (Glocke oben rechts) wirst du immer benachrichtigt – live, sobald etwas passiert.')),
            h(
              'label',
              { class: 'check' },
              emailIn,
              h(
                'span',
                null,
                h('strong', null, 'Zusätzlich per E-Mail'),
                h('div', { class: 'hint' }, state.config.mailEnabled ? 'Mit Kalendereinladung im Anhang (Outlook, Google, Apple …).' : 'Hinweis: Der E-Mail-Versand ist auf diesem Server noch nicht eingerichtet.'),
              ),
            ),
            field('Erinnerung vor Terminbeginn', reminderSel, 'Gilt für eigene Buchungen und Einladungen.'),
            h('div', { class: 'field' }, h('span', { class: 'label' }, 'Desktop-Benachrichtigungen'), desktopBox),
            h('div', null, testBtn),
          ),
        ),
        calCard,
      ),
      h(
        'div',
        { class: 'stack' },
        h(
          'div',
          { class: 'card' },
          h('div', { class: 'card-head' }, h('h2', null, icon('user'), 'Konto')),
          h('div', { class: 'card-body form' }, h('div', { class: 'field' }, h('label', null, 'Name'), h('div', { class: 'copy-field' }, nameIn, saveName))),
        ),
        h('div', { class: 'card' }, h('div', { class: 'card-head' }, h('h2', null, icon('lock'), 'Passwort')), h('div', { class: 'card-body' }, pwForm)),
      ),
    ),
  );
}
