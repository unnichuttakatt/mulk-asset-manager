// Control for every company asset in the register.
// Computers, printers, and phones store a decision here. A visible enrollment
// on the device is what applies it. This page does not record keystrokes,
// screenshots, or location.

import { store, loadAssets, ctx } from '../data.js';
import { esc, fmtDateTime, modal, toast } from '../ui.js';

const LOCAL_KEY = 'am.laptop-control.v1';

const POLICIES = {
  baseline: {
    label: 'Baseline',
    rules: ['USB storage blocked', 'Personal cloud blocked', 'Mail to outside addresses held', 'Printing a labeled file warns', 'Copying a labeled file warns'],
  },
  finance: {
    label: 'Finance',
    rules: ['USB storage blocked', 'Personal cloud blocked', 'Mail to outside addresses held', 'Printing a labeled file blocked', 'Copying a labeled file blocked'],
  },
  engineering: {
    label: 'Engineering',
    rules: ['USB storage read only', 'Personal cloud warns', 'Mail to outside addresses warns', 'Printing a labeled file warns', 'Copying a labeled file warns'],
  },
  legal: {
    label: 'Legal',
    rules: ['USB storage blocked', 'Personal cloud blocked', 'Mail to outside addresses held', 'Printing a labeled file blocked', 'Copying a labeled file blocked'],
  },
  executive: {
    label: 'Executive',
    rules: ['USB storage blocked', 'Personal cloud blocked', 'Mail to outside addresses held', 'Printing a labeled file warns', 'Copying a labeled file blocked'],
  },
  field: {
    label: 'Field',
    rules: ['USB storage read only', 'Personal cloud blocked', 'Mail to outside addresses warns', 'Printing a labeled file warns', 'Copying a labeled file warns'],
  },
};

const PRINT_MODES = {
  open: 'Open',
  release: 'Hold for release',
  mono: 'Black and white only',
  stopped: 'Stopped',
};

const KINDS = {
  laptop: 'Laptop',
  desktop: 'Desktop',
  printer: 'Printer',
  mobile: 'Phone',
  other: 'Other',
};

const SETUP_SQL = `create table if not exists public.laptop_controls (
  asset_id uuid primary key references public.assets(id) on delete cascade,
  admin text not null default 'standard' check (admin in ('standard','elevated','standing')),
  elevation_ends_at timestamptz,
  admin_note text,
  policy text not null default 'baseline' check (policy in ('baseline','finance','engineering','legal','executive','field')),
  hold boolean not null default false,
  hold_reason text,
  updated_at timestamptz not null default now(),
  updated_by text default public.current_email()
);
drop trigger if exists laptop_controls_touch on public.laptop_controls;
create trigger laptop_controls_touch before update on public.laptop_controls
for each row execute function public.touch_updated_at();
create table if not exists public.laptop_control_events (
  id bigint generated always as identity primary key,
  asset_id uuid not null references public.assets(id) on delete cascade,
  action text not null,
  detail text,
  performed_by text not null default public.current_email(),
  created_at timestamptz not null default now()
);
alter table public.laptop_controls enable row level security;
alter table public.laptop_control_events enable row level security;
drop policy if exists admins_all on public.laptop_controls;
create policy admins_all on public.laptop_controls
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
drop policy if exists admins_all on public.laptop_control_events;
create policy admins_all on public.laptop_control_events
  for all to authenticated using (public.is_admin()) with check (public.is_admin());
revoke all on public.laptop_controls, public.laptop_control_events from anon;
grant select, insert, update, delete on public.laptop_controls, public.laptop_control_events to authenticated;
grant usage, select on sequence public.laptop_control_events_id_seq to authenticated;
alter table public.laptop_controls add column if not exists connection text not null default 'not_connected';
alter table public.laptop_controls drop constraint if exists laptop_controls_connection_check;
alter table public.laptop_controls add constraint laptop_controls_connection_check check (connection in ('not_connected','enrolled'));
alter table public.laptop_controls add column if not exists print_mode text not null default 'open';
alter table public.laptop_controls drop constraint if exists laptop_controls_print_mode_check;
alter table public.laptop_controls add constraint laptop_controls_print_mode_check check (print_mode in ('open','release','mono','stopped'));`;

const BASE_COLS = 'asset_id,admin,elevation_ends_at,admin_note,policy,hold,hold_reason,updated_at,updated_by';
const WIDE_COLS = BASE_COLS + ',connection,print_mode';

const ui = {
  q: '',
  kind: 'all',
  selected: null,
  source: 'db',
  wide: true,
  controls: new Map(),
  events: [],
  assets: [],
};

function kindOf(a) {
  const blob = [a.category, a.description, a.model, a.brand, a.tag].filter(Boolean).join(' ');
  if (/\/LAP\//i.test(a.tag || '') || /laptop|notebook|macbook|thinkpad|latitude|elitebook|probook|chromebook/i.test(blob)) return 'laptop';
  if (/desktop|workstation|\bimac\b|optiplex|thinkcentre|all-in-one/i.test(blob)) return 'desktop';
  if (/printer|plotter|\bmfp\b|multifunction/i.test(blob)) return 'printer';
  if (/phone|mobile|iphone|ipad|tablet/i.test(blob)) return 'mobile';
  return 'other';
}

function enrollable(kind) {
  return kind === 'laptop' || kind === 'desktop' || kind === 'printer' || kind === 'mobile';
}

function suggestPolicy(a) {
  const d = `${a.department || ''} ${a.location || ''}`.toLowerCase();
  if (/financ|account|treasury/.test(d)) return 'finance';
  if (/legal|counsel/.test(d)) return 'legal';
  if (/execut|director|board/.test(d)) return 'executive';
  if (/field|yard|site office/.test(d)) return 'field';
  if (/engineer|software|develop/.test(d)) return 'engineering';
  return 'baseline';
}

function liveAdmin(c) {
  if (!c || c.admin === 'standard') return 'standard';
  if (c.admin === 'standing') return 'standing';
  if (c.admin === 'elevated' && c.elevation_ends_at && new Date(c.elevation_ends_at).getTime() > Date.now()) return 'elevated';
  return 'standard';
}

function adminText(c) {
  const live = liveAdmin(c);
  if (live === 'standing') return 'Standing admin';
  if (live === 'elevated') return 'Temporary until ' + fmtDateTime(c.elevation_ends_at);
  return 'Standard user';
}

function adminClass(c) {
  const live = liveAdmin(c);
  if (live === 'standing') return 'st-broken';
  if (live === 'elevated') return 'st-checked_out';
  return 'st-available';
}

function untilGstClose() {
  const offset = 4 * 60 * 60000;
  const now = Date.now();
  const g = new Date(now + offset);
  let close = Date.UTC(g.getUTCFullYear(), g.getUTCMonth(), g.getUTCDate(), 18, 0, 0) - offset;
  if (close <= now) close += 86400000;
  return new Date(close).toISOString();
}

function readLocal() {
  try { return JSON.parse(localStorage.getItem(LOCAL_KEY) || 'null') || { controls: {}, events: [] }; }
  catch { return { controls: {}, events: [] }; }
}

function missingTable(err) {
  const m = String(err?.message || err || '').toLowerCase();
  return err?.status === 404 || m.includes('schema cache') || m.includes('does not exist') || m.includes('could not find the table') || (m.includes('relation') && m.includes('does not exist'));
}

function missingColumn(err) {
  const m = String(err?.message || err || '').toLowerCase();
  return m.includes('connection') || m.includes('print_mode');
}

function who() {
  return ctx.user?.email || 'admin';
}

function blank(asset) {
  return {
    asset_id: asset.id,
    admin: 'standard',
    elevation_ends_at: null,
    admin_note: null,
    policy: suggestPolicy(asset),
    hold: false,
    hold_reason: null,
    connection: 'not_connected',
    print_mode: 'open',
    _saved: false,
  };
}

function current(asset) {
  return ui.controls.get(asset.id) || blank(asset);
}

function normalise(row) {
  return {
    ...row,
    hold: !!row.hold,
    connection: row.connection === 'enrolled' ? 'enrolled' : 'not_connected',
    print_mode: PRINT_MODES[row.print_mode] ? row.print_mode : 'open',
    policy: POLICIES[row.policy] ? row.policy : 'baseline',
    _saved: true,
  };
}

async function uploadLocalIfEmpty() {
  const local = readLocal();
  const pending = Object.values(local.controls || {});
  if (!pending.length || ui.controls.size) return;
  for (const row of pending) {
    await store.db.insert('laptop_controls', dbBody(row));
    ui.controls.set(row.asset_id, normalise({ ...row, ...dbBody(row) }));
  }
  for (const ev of [...(local.events || [])].reverse()) {
    await store.db.insert('laptop_control_events', { asset_id: ev.asset_id, action: ev.action || 'note', detail: ev.detail || '' });
  }
  localStorage.removeItem(LOCAL_KEY);
  ui.events = await store.db.select('laptop_control_events', { select: 'id,asset_id,action,detail,performed_by,created_at', order: 'created_at.desc', limit: '40' });
}

function dbBody(next) {
  const body = {
    asset_id: next.asset_id,
    admin: next.admin || 'standard',
    elevation_ends_at: next.elevation_ends_at || null,
    admin_note: next.admin_note || null,
    policy: POLICIES[next.policy] ? next.policy : 'baseline',
    hold: !!next.hold,
    hold_reason: next.hold_reason || null,
  };
  if (ui.wide) {
    body.connection = next.connection === 'enrolled' ? 'enrolled' : 'not_connected';
    body.print_mode = PRINT_MODES[next.print_mode] ? next.print_mode : 'open';
  }
  return body;
}

async function loadControls() {
  try {
    let rows;
    try {
      rows = await store.db.selectAll('laptop_controls', { select: WIDE_COLS });
      ui.wide = true;
    } catch (err) {
      if (!missingColumn(err)) throw err;
      ui.wide = false;
      rows = await store.db.selectAll('laptop_controls', { select: BASE_COLS });
    }
    const events = await store.db.select('laptop_control_events', { select: 'id,asset_id,action,detail,performed_by,created_at', order: 'created_at.desc', limit: '40' });
    ui.source = 'db';
    ui.controls = new Map(rows.map(r => [r.asset_id, normalise(r)]));
    ui.events = events;
    await uploadLocalIfEmpty();
  } catch (err) {
    if (!missingTable(err)) throw err;
    const local = readLocal();
    ui.source = 'local';
    ui.wide = true;
    ui.controls = new Map(Object.values(local.controls || {}).map(r => [r.asset_id, normalise(r)]));
    ui.events = local.events || [];
  }
}

async function persist(asset, next, action, detail) {
  const full = { ...blank(asset), ...next, asset_id: asset.id };
  const event = { asset_id: asset.id, action, detail, performed_by: who(), created_at: new Date().toISOString() };
  if (ui.source === 'db') {
    const write = async () => {
      const body = dbBody(full);
      delete body.asset_id;
      if (ui.controls.get(asset.id)?._saved) await store.db.update('laptop_controls', { asset_id: `eq.${asset.id}` }, body);
      else await store.db.insert('laptop_controls', { asset_id: asset.id, ...body });
    };
    try {
      await write();
    } catch (err) {
      if (!ui.wide || !missingColumn(err)) throw err;
      ui.wide = false;
      await write();
    }
    await store.db.insert('laptop_control_events', { asset_id: asset.id, action, detail });
    ui.controls.set(asset.id, normalise(full));
    ui.events = [{ ...event, id: 'new-' + Date.now() }, ...ui.events].slice(0, 40);
  } else {
    const local = readLocal();
    local.controls[asset.id] = full;
    local.events = [{ ...event, id: 'local-' + Date.now() }, ...(local.events || [])].slice(0, 200);
    localStorage.setItem(LOCAL_KEY, JSON.stringify(local));
    ui.controls.set(asset.id, normalise(full));
    ui.events = local.events;
  }
}

function filtered() {
  const q = ui.q.trim().toLowerCase();
  return ui.assets.filter(a => {
    if (ui.kind !== 'all' && kindOf(a) !== ui.kind) return false;
    if (!q) return true;
    return [a.tag, a.description, a.category, a.assigned_to, a.site, a.department, a.serial_no, a.model].join(' ').toLowerCase().includes(q);
  });
}

function controlSummary(asset, c) {
  const kind = kindOf(asset);
  if (kind === 'laptop' || kind === 'desktop') return adminText(c);
  if (kind === 'printer') return PRINT_MODES[c.print_mode] || 'Open';
  if (kind === 'mobile') return c.connection === 'enrolled' ? 'Company profile' : 'Not enrolled';
  return 'Register only';
}

function connectionText(asset, c) {
  if (!enrollable(kindOf(asset))) return 'In the register';
  return c.connection === 'enrolled' ? 'Enrolled' : 'Not enrolled';
}

export async function controlView(main) {
  main.innerHTML = `<div class="boot">Loading assets…</div>`;
  try {
    const assets = await loadAssets();
    ui.assets = assets.filter(a => a.status !== 'disposed').sort((a, b) => (a.tag || '').localeCompare(b.tag || ''));
    await loadControls();
  } catch (err) {
    main.innerHTML = `<div class="page-head"><div><h1>Control</h1></div></div><div class="err">${esc(err.message || String(err))}</div>`;
    return;
  }
  paint(main);
}

function paint(main) {
  const focusId = document.activeElement?.id;
  const caret = document.activeElement?.selectionStart;
  const rows = filtered();
  const counts = { computers: 0, printers: 0, hold: 0, waiting: 0 };
  for (const a of ui.assets) {
    const kind = kindOf(a);
    const c = current(a);
    if (kind === 'laptop' || kind === 'desktop') counts.computers += 1;
    if (kind === 'printer') counts.printers += 1;
    if (c.hold) counts.hold += 1;
    if (enrollable(kind) && c.connection !== 'enrolled') counts.waiting += 1;
  }
  const selected = ui.assets.find(a => a.id === ui.selected) || null;
  const kindOptions = Object.entries(KINDS).map(([k, label]) => `<option value="${k}" ${ui.kind === k ? 'selected' : ''}>${label}</option>`).join('');

  main.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Control</h1>
        <p>${ui.assets.length} active asset${ui.assets.length === 1 ? '' : 's'} from the register. One list for laptops, desktops, printers, phones, and everything else.</p>
      </div>
    </div>
    <div class="note" style="margin-bottom:16px">
      <strong>How a device gets connected.</strong>
      A laptop or desktop is connected when the person enrolls it in Microsoft Intune (Windows) or Jamf (Mac). They can see that enrollment.
      A printer is connected when you add its queue on the company print server.
      A phone is connected when the person installs the company management profile.
      Monitors and other items stay under this register: who has them, where they are, and whether they are on hold.
      Saving a decision here does not change the device until that enrollment exists. This page does not record keystrokes, screenshots, or location.
    </div>
    ${ui.source === 'local' ? `
      <div class="err" style="margin-bottom:16px">
        <strong>Shared storage is not set up yet.</strong> Decisions stay in this browser until you run <span class="mono">supabase/laptop-control.sql</span> once in the Supabase SQL editor.
        <div class="row" style="margin-top:8px"><button type="button" class="btn sm" id="copy-sql">Copy the SQL</button></div>
      </div>` : ''}
    ${ui.source === 'db' && !ui.wide ? `
      <div class="err" style="margin-bottom:16px">
        <strong>Connection and printer settings are not stored for every admin yet.</strong> Run <span class="mono">supabase/laptop-control.sql</span> again so the new columns are added. Until then, those two fields stay in this browser.
        <div class="row" style="margin-top:8px"><button type="button" class="btn sm" id="copy-sql">Copy the SQL</button></div>
      </div>` : ''}
    <div class="kpis">
      <div class="card kpi"><div class="k-label">Assets</div><div class="k-val">${ui.assets.length}</div></div>
      <div class="card kpi"><div class="k-label">Computers</div><div class="k-val">${counts.computers}</div></div>
      <div class="card kpi"><div class="k-label">Printers</div><div class="k-val">${counts.printers}</div></div>
      <div class="card kpi"><div class="k-label">Not enrolled</div><div class="k-val">${counts.waiting}</div></div>
      <div class="card kpi"><div class="k-label">On hold</div><div class="k-val">${counts.hold}</div></div>
    </div>
    <div class="card" style="margin-bottom:16px">
      <div class="filters">
        <input id="cq" class="search" placeholder="Search tag, person, serial, site" value="${esc(ui.q)}" />
        <select id="f-kind">
          <option value="all" ${ui.kind === 'all' ? 'selected' : ''}>All kinds</option>
          ${kindOptions}
        </select>
      </div>
      ${rows.length ? `<div class="tbl-wrap"><table class="tbl"><thead><tr>
        <th>Tag</th><th>Asset</th><th>Kind</th><th>Person</th><th>Site</th><th>Control</th><th>Connection</th><th>Hold</th>
      </tr></thead><tbody>
        ${rows.map(a => {
          const c = current(a);
          const enrolled = !enrollable(kindOf(a)) || c.connection === 'enrolled';
          return `<tr class="clickable${a.id === ui.selected ? ' on' : ''}" data-id="${esc(a.id)}">
            <td><span class="tag">${esc(a.tag)}</span></td>
            <td class="desc">${esc(a.description || a.model || a.category || '')}</td>
            <td>${esc(KINDS[kindOf(a)])}</td>
            <td>${esc(a.assigned_to || '—')}</td>
            <td>${esc(a.site || '—')}</td>
            <td>${esc(controlSummary(a, c))}</td>
            <td>${enrolled ? esc(connectionText(a, c)) : `<span class="badge st-under_repair">${esc(connectionText(a, c))}</span>`}</td>
            <td>${c.hold ? '<span class="badge st-broken">On hold</span>' : '<span class="muted">No</span>'}</td>
          </tr>`;
        }).join('')}
      </tbody></table></div>` : `<div class="empty">${ui.assets.length ? 'No assets match these filters.' : 'No active assets in the register yet.'}</div>`}
    </div>
    ${selected ? detail(selected) : '<div class="note">Select an asset to see how it connects and to set its control.</div>'}
    <div class="card" style="margin-top:16px">
      <div class="card-h"><h2>Decisions</h2><span class="muted">${ui.source === 'db' ? 'Shared with every admin' : 'This browser only'}</span></div>
      ${ui.events.length ? `<div class="tbl-wrap"><table class="tbl"><thead><tr><th>When</th><th>Asset</th><th>Decision</th><th>By</th></tr></thead><tbody>
        ${ui.events.slice(0, 20).map(e => {
          const a = ui.assets.find(x => x.id === e.asset_id);
          return `<tr>
            <td>${fmtDateTime(e.created_at)}</td>
            <td>${a ? `<span class="tag">${esc(a.tag)}</span>` : '<span class="muted">Removed asset</span>'}</td>
            <td>${esc(e.detail || e.action)}</td>
            <td class="sub">${esc(e.performed_by || '')}</td>
          </tr>`;
        }).join('')}
      </tbody></table></div>` : '<div class="empty">No control decisions yet.</div>'}
    </div>`;

  const qEl = document.getElementById('cq');
  let timer;
  qEl.oninput = () => {
    clearTimeout(timer);
    timer = setTimeout(() => { ui.q = qEl.value; paint(main); }, 160);
  };
  document.getElementById('f-kind').onchange = (e) => { ui.kind = e.target.value; paint(main); };
  main.querySelectorAll('tr[data-id]').forEach(tr => {
    tr.onclick = () => { ui.selected = tr.dataset.id; paint(main); };
  });
  document.getElementById('copy-sql')?.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(SETUP_SQL);
      toast('SQL copied. Paste it in the Supabase SQL editor and run it.');
    } catch {
      toast('Could not copy. Open supabase/laptop-control.sql in the project.', true);
    }
  });
  if (selected) bindDetail(main, selected);
  if (focusId === 'cq' || focusId === 'f-kind') {
    const el = document.getElementById(focusId);
    if (el) {
      el.focus();
      if (focusId === 'cq' && caret != null) el.setSelectionRange(caret, caret);
    }
  }
}

function steps(kind) {
  if (kind === 'laptop' || kind === 'desktop') {
    return [
      'Match the serial number on the computer to this asset tag.',
      'The person signs in with their company account.',
      'Windows: Settings, Accounts, Access work or school, then Connect, and enroll in the company Intune. Mac: open the Jamf enrollment IT sends. The person can see this. It is not hidden.',
      'Return here and choose Mark enrolled. Until then, the buttons below only save the decision. They do not change the computer.',
    ];
  }
  if (kind === 'printer') {
    return [
      'Confirm the site and location on this asset match the printer on the floor.',
      'Give the printer a fixed address on the office network.',
      'Add that queue on the company print server and set it to the mode you choose below.',
      'Choose Mark enrolled once the queue exists. Until then this page only stores the mode.',
    ];
  }
  if (kind === 'mobile') {
    return [
      'Match the serial number to this asset tag.',
      'The person installs the company management profile, through Intune Company Portal or Apple Business Manager. They can see the profile.',
      'Choose Mark enrolled after that profile is on the device. This page does not track where the phone is.',
    ];
  }
  return [
    'This asset is controlled from the register. Check it out to a person, and place it on hold when it should not be used.',
    'There is no remote agent for this kind of asset.',
  ];
}

function detail(a) {
  const c = current(a);
  const kind = kindOf(a);
  const policy = POLICIES[c.policy] || POLICIES.baseline;
  const options = Object.entries(POLICIES).map(([k, v]) => `<option value="${k}" ${c.policy === k ? 'selected' : ''}>${esc(v.label)}</option>`).join('');
  const printOptions = Object.entries(PRINT_MODES).map(([k, label]) => `<option value="${k}" ${c.print_mode === k ? 'selected' : ''}>${esc(label)}</option>`).join('');
  const computer = kind === 'laptop' || kind === 'desktop';
  return `<div class="card">
    <div class="card-h">
      <h2><span class="tag">${esc(a.tag)}</span> ${esc(a.description || a.model || KINDS[kind])}</h2>
      <a href="#/asset/${esc(a.id)}">Open asset</a>
    </div>
    <div class="card-b stack">
      <div class="muted">${esc(KINDS[kind])}${a.assigned_to ? ' · ' + esc(a.assigned_to) : ''}${a.department ? ' · ' + esc(a.department) : ''}${a.site ? ' · ' + esc(a.site) : ''}${a.serial_no ? ' · ' + esc(a.serial_no) : ''}</div>
      <div>
        <h2 style="margin-bottom:8px">Connect this ${esc(KINDS[kind].toLowerCase())}</h2>
        <ol class="muted" style="margin:0; padding-left:18px">
          ${steps(kind).map(s => `<li>${esc(s)}</li>`).join('')}
        </ol>
        ${enrollable(kind) ? `<div class="row" style="margin-top:10px">
          <span class="badge ${c.connection === 'enrolled' ? 'st-available' : 'st-under_repair'}">${esc(connectionText(a, c))}</span>
          <button type="button" class="btn sm" data-act="enrolled">Mark enrolled</button>
          <button type="button" class="btn sm" data-act="not-enrolled">Mark not enrolled</button>
        </div>` : ''}
      </div>
      ${computer ? `<div>
        <h2 style="margin-bottom:8px">Admin rights</h2>
        <p class="muted" style="margin:0 0 10px">Standard user is the default. A timed window ends on its own. Standing admin needs a written reason and stays until you revoke it. A hold does not wipe the computer.</p>
        <div class="row">
          <span class="badge ${adminClass(c)}">${esc(adminText(c))}</span>
          ${c.admin_note ? `<span class="muted">${esc(c.admin_note)}</span>` : ''}
        </div>
        <div class="row" style="margin-top:10px">
          <button type="button" class="btn sm" data-act="standard">Standard user</button>
          <button type="button" class="btn sm" data-act="1h">Grant 1 hour</button>
          <button type="button" class="btn sm" data-act="4h">Grant 4 hours</button>
          <button type="button" class="btn sm" data-act="close">Until 18:00 GST</button>
          <button type="button" class="btn sm" data-act="standing">Standing admin</button>
        </div>
      </div>
      <div>
        <h2 style="margin-bottom:8px">Data leaving the computer</h2>
        <label class="f" style="max-width:280px">Rule set
          <select id="policy">${options}</select>
        </label>
        <ul class="muted" style="margin:10px 0 0; padding-left:18px">
          ${policy.rules.map(r => `<li>${esc(r)}</li>`).join('')}
        </ul>
      </div>` : ''}
      ${kind === 'printer' ? `<div>
        <h2 style="margin-bottom:8px">Print queue</h2>
        <label class="f" style="max-width:280px">Mode the print server should apply
          <select id="print-mode">${printOptions}</select>
        </label>
        <p class="muted" style="margin:10px 0 0">Open accepts jobs. Hold for release keeps a job until someone collects it at the printer. Black and white only rejects color. Stopped accepts nothing.</p>
      </div>` : ''}
      <div>
        <h2 style="margin-bottom:8px">Hold</h2>
        ${c.hold
          ? `<p style="margin:0 0 10px">On hold${c.hold_reason ? ': ' + esc(c.hold_reason) : ''}. The person should see this reason.</p><button type="button" class="btn sm" data-act="release">Release hold</button>`
          : '<p class="muted" style="margin:0 0 10px">A hold means this asset should not be used until you release it. Write the reason the person will see. A hold does not wipe a computer.</p><button type="button" class="btn sm" data-act="hold">Place on hold</button>'}
      </div>
    </div>
  </div>`;
}

function bindDetail(main, asset) {
  document.getElementById('policy')?.addEventListener('change', async (e) => {
    const policy = e.target.value;
    try {
      await save(main, asset, { ...current(asset), policy }, 'policy', `Data rules set to ${POLICIES[policy].label}`);
    } catch (err) { toast(err.message || String(err), true); }
  });
  document.getElementById('print-mode')?.addEventListener('change', async (e) => {
    const print_mode = e.target.value;
    try {
      await save(main, asset, { ...current(asset), print_mode }, 'printer', `Print queue set to ${PRINT_MODES[print_mode]}`);
    } catch (err) { toast(err.message || String(err), true); }
  });
  main.querySelectorAll('[data-act]').forEach(btn => {
    btn.onclick = () => act(main, asset, btn.dataset.act);
  });
}

async function act(main, asset, kind) {
  const c = current(asset);
  const noun = KINDS[kindOf(asset)].toLowerCase();
  try {
    if (kind === 'enrolled') {
      await save(main, asset, { ...c, connection: 'enrolled' }, 'connection', `${KINDS[kindOf(asset)]} marked enrolled`);
    } else if (kind === 'not-enrolled') {
      await save(main, asset, { ...c, connection: 'not_connected' }, 'connection', `${KINDS[kindOf(asset)]} marked not enrolled`);
    } else if (kind === 'standard') {
      await save(main, asset, { ...c, admin: 'standard', elevation_ends_at: null, admin_note: null }, 'admin', 'Admin rights set to standard user');
    } else if (kind === '1h' || kind === '4h') {
      const hours = kind === '1h' ? 1 : 4;
      const ends = new Date(Date.now() + hours * 3600000).toISOString();
      await save(main, asset, { ...c, admin: 'elevated', elevation_ends_at: ends, admin_note: null }, 'admin', `Temporary admin for ${hours} hour${hours === 1 ? '' : 's'}, until ${fmtDateTime(ends)}`);
    } else if (kind === 'close') {
      const ends = untilGstClose();
      await save(main, asset, { ...c, admin: 'elevated', elevation_ends_at: ends, admin_note: null }, 'admin', `Temporary admin until 18:00 GST (${fmtDateTime(ends)})`);
    } else if (kind === 'standing') {
      let reason = '';
      const ok = await modal({
        title: 'Standing admin',
        submit: 'Grant',
        body: `<label class="f">Reason the person and the next admin can read<textarea name="reason" required placeholder="Why this computer needs admin rights that do not expire"></textarea></label>`,
        onSubmit(form) {
          reason = form.reason.value.trim();
          if (reason.length < 8) throw new Error('Write a reason of at least a few words.');
        },
      });
      if (!ok) return;
      await save(main, asset, { ...current(asset), admin: 'standing', elevation_ends_at: null, admin_note: reason }, 'admin', `Standing admin: ${reason}`);
    } else if (kind === 'hold') {
      let reason = '';
      const ok = await modal({
        title: 'Place on hold',
        submit: 'Hold asset',
        danger: true,
        body: `<p style="margin:0">The person should be able to read this reason. A hold does not wipe a computer.</p>
          <label class="f">Reason<textarea name="reason" required placeholder="Why company use of this ${esc(noun)} is paused"></textarea></label>`,
        onSubmit(form) {
          reason = form.reason.value.trim();
          if (reason.length < 8) throw new Error('Write a reason of at least a few words.');
        },
      });
      if (!ok) return;
      await save(main, asset, { ...current(asset), hold: true, hold_reason: reason }, 'hold', `Placed on hold: ${reason}`);
    } else if (kind === 'release') {
      await save(main, asset, { ...c, hold: false, hold_reason: null }, 'hold', 'Hold released');
    }
  } catch (err) {
    toast(err.message || String(err), true);
  }
}

async function save(main, asset, next, action, detail) {
  await persist(asset, next, action, detail);
  toast('Saved');
  paint(main);
}
