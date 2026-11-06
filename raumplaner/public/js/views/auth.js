import { post } from '../api.js';
import { state } from '../state.js';
import { field, h, icon, setBusy } from '../ui.js';

function brand(subtitle) {
  return h(
    'div',
    { class: 'auth-brand' },
    h('div', { class: 'brand-mark' }, icon('door')),
    h('div', null, h('h1', null, state.config?.orgName || 'Raumplaner'), h('div', { class: 'muted small' }, subtitle)),
  );
}

function shell(...content) {
  return h('div', { class: 'auth-wrap' }, h('div', { class: 'card auth-card' }, h('div', { class: 'card-body' }, ...content)));
}

/** Ersteinrichtung: erstes Admin-Konto anlegen. */
export function renderSetup(root, onDone) {
  const org = h('input', { class: 'input', autocomplete: 'organization', placeholder: 'z. B. Muster GmbH', required: true });
  const name = h('input', { class: 'input', autocomplete: 'name', required: true });
  const email = h('input', { class: 'input', type: 'email', autocomplete: 'email', required: true });
  const pw = h('input', { class: 'input', type: 'password', autocomplete: 'new-password', minlength: 8, required: true });
  const err = h('div', { class: 'form-error', role: 'alert' });
  const btn = h('button', { class: 'btn btn-primary', type: 'submit' }, 'Einrichtung abschließen');
  const form = h(
    'form',
    {
      class: 'form',
      onSubmit: async (e) => {
        e.preventDefault();
        err.textContent = '';
        setBusy(btn, true);
        try {
          const res = await post('/api/setup', { orgName: org.value, name: name.value, email: email.value, password: pw.value });
          onDone(res);
        } catch (ex) {
          err.textContent = ex.message;
        } finally {
          setBusy(btn, false);
        }
      },
    },
    h('div', { class: 'notice' }, icon('info'), h('div', null, 'Willkommen! Lege jetzt das erste Konto an. Es erhält Administratorrechte und kann danach Gebäude, Etagen und Räume hinterlegen.')),
    field('Name der Organisation', org),
    field('Dein Name', name),
    field('E-Mail-Adresse', email),
    field('Passwort', pw, 'Mindestens 8 Zeichen.'),
    err,
    btn,
  );
  root.replaceChildren(shell(brand('Ersteinrichtung'), form));
  org.focus();
}

/** Anmeldung bzw. Registrierung. */
export function renderLogin(root, onDone, { mode = 'login' } = {}) {
  const allowRegistration = state.config?.allowRegistration;
  const isRegister = mode === 'register' && allowRegistration;
  const name = h('input', { class: 'input', autocomplete: 'name', required: true });
  const email = h('input', { class: 'input', type: 'email', autocomplete: 'email', required: true });
  const pw = h('input', { class: 'input', type: 'password', autocomplete: isRegister ? 'new-password' : 'current-password', required: true });
  const err = h('div', { class: 'form-error', role: 'alert' });
  const btn = h('button', { class: 'btn btn-primary', type: 'submit' }, isRegister ? 'Konto anlegen' : 'Anmelden');

  const form = h(
    'form',
    {
      class: 'form',
      onSubmit: async (e) => {
        e.preventDefault();
        err.textContent = '';
        setBusy(btn, true);
        try {
          const res = isRegister
            ? await post('/api/auth/register', { name: name.value, email: email.value, password: pw.value })
            : await post('/api/auth/login', { email: email.value, password: pw.value });
          onDone(res);
        } catch (ex) {
          err.textContent = ex.message;
        } finally {
          setBusy(btn, false);
        }
      },
    },
    isRegister ? field('Name', name) : null,
    field('E-Mail-Adresse', email, isRegister && state.config.allowedEmailDomains ? `Erlaubt: ${state.config.allowedEmailDomains}` : null),
    field('Passwort', pw, isRegister ? 'Mindestens 8 Zeichen.' : null),
    err,
    btn,
    allowRegistration
      ? h(
          'p',
          { class: 'muted small', style: { textAlign: 'center' } },
          isRegister ? 'Schon ein Konto? ' : 'Noch kein Konto? ',
          h(
            'button',
            { class: 'btn btn-link', type: 'button', onClick: () => renderLogin(root, onDone, { mode: isRegister ? 'login' : 'register' }) },
            isRegister ? 'Anmelden' : 'Jetzt registrieren',
          ),
        )
      : h('p', { class: 'muted small', style: { textAlign: 'center' } }, 'Noch kein Konto? Bitte wende dich an die Administration.'),
  );
  root.replaceChildren(shell(brand(isRegister ? 'Konto anlegen' : 'Räume finden, buchen und immer informiert sein'), form));
  (isRegister ? name : email).focus();
}
