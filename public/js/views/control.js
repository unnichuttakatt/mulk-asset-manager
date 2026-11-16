// Laptop control: admin rights and data-leaving rules for company laptops
// already in the asset register. Records the decision only.

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
grant usage, select on sequence public.laptop_control_events_id_seq to authenticated;`;

const ui = {
  q: '',
  admin: 'all',
  policy: 'all',
  selected: null,
  source: 'db',
  controls: new Map(),
  events: [],
  laptops: [],
};

const LAPTOP = /laptop|notebook|macbook|thinkpad|latitude|elitebook|probook|chromebook/i;

function isLaptop(a) {
  if (!a || a.status === 'disposed') return false;
  if (/\/LAP\//i.test(a.tag || '')) return true;
  return LAPTOP.test([a.category, a.description, a.model, a.brand].filter(Boolean).join(' '));
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
  return err?.status === 404 || m.includes('schema cache') || m.includes('does not exist') || m.includes('could not find');
}

async function uploadLocalIfEmpty() {
  const local = readLocal();
  const pending = Object.values(local.controls || {});
  if (!pending.length || ui.controls.size) return;
  for (const row of pending) {
    const body = {
      asset_id: row.asset_id,
      admin: row.admin,
      elevation_ends_at: row.elevation_ends_at,
      admin_note: row.admin_note,
      policy: row.policy,
      hold: !!row.hold,
      hold_reason: row.hold_reason,
    };
    await store.db.insert('laptop_controls', body);
    ui.controls.set(row.asset_id, { ...body, _saved: true });
  }
  for (const ev of [...(local.events || [])].reverse()) {
    await store.db.insert('laptop_control_events', { asset_id: ev.asset_id, action: ev.action || 'note', detail: ev.detail || '' });
  }
  localStorage.removeItem(LOCAL_KEY);
  ui.events = await store.db.select('laptop_control_events', { select: 'id,asset_id,action,detail,performed_by,created_at', order: 'created_at.desc', limit: '40' });
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
    _saved: false,
  };
}

function current(asset) {
  return ui.controls.get(asset.id) || blank(asset);
}

async function loadControls() {
  try {
    const [rows, events] = await Promise.all([
      store.db.selectAll('laptop_controls', { select: 'asset_id,admin,elevation_ends_at,admin_note,policy,hold,hold_reason,updated_at,updated_by' }),
      store.db.select('laptop_control_events', { select: 'id,asset_id,action,detail,performed_by,created_at', order: 'created_at.desc', limit: '40' }),
    ]);
    ui.source = 'db';
    ui.controls = new Map(rows.map(r => [r.asset_id, { ...r, hold: !!r.hold, _saved: true }]));
    ui.events = events;
    await uploadLocalIfEmpty();
  } catch (err) {
    if (!missingTable(err)) throw err;
    const local = readLocal();
    ui.source = 'local';
    ui.controls = new Map(Object.values(local.controls || {}).map(r => [r.asset_id, { ...r, _saved: true }]));
    ui.events = local.events || [];
  }
}

async function persist(asset, next, action, detail) {
  const row = {
    asset_id: asset.id,
    admin: next.admin,
    elevation_ends_at: next.elevation_ends_at,
    admin_note: next.admin_note,
    policy: next.policy,
    hold: !!next.hold,
    hold_reason: next.hold_reason,
  };
  const event = { asset_id: asset.id, action, detail, performed_by: who(), created_at: new Date().toISOString() };
  if (ui.source === 'db') {
    if (ui.controls.get(asset.id)?._saved) await store.db.update('laptop_controls', { asset_id: `eq.${asset.id}` }, row);
    else await store.db.insert('laptop_controls', row);
    await store.db.insert('laptop_control_events', { asset_id: asset.id, action, detail });
    ui.controls.set(asset.id, { ...row, _saved: true });
    ui.events = [{ ...event, id: 'new-' + Date.now() }, ...ui.events].slice(0, 40);
  } else {
    const local = readLocal();
    local.controls[asset.id] = row;
    local.events = [{ ...event, id: 'local-' + Date.now() }, ...(local.events || [])].slice(0, 200);
    localStorage.setItem(LOCAL_KEY, JSON.stringify(local));
    ui.controls.set(asset.id, { ...row, _saved: true });
    ui.events = local.events;
  }
}

function filtered() {
  const q = ui.q.trim().toLowerCase();
  return ui.laptops.filter(a => {
    const c = current(a);
    if (ui.admin !== 'all' && liveAdmin(c) !== ui.admin) return false;
    if (ui.policy !== 'all' && c.policy !== ui.policy) return false;
    if (!q) return true;
    return [a.tag, a.description, a.assigned_to, a.site, a.department, a.serial_no, a.model].join(' ').toLowerCase().includes(q);
  });
}

export async function controlView(main) {
  main.innerHTML = `<div class="boot">Loading laptops…</div>`;
  try {
    const assets = await loadAssets();
    ui.laptops = assets.filter(isLaptop).sort((a, b) => (a.tag || '').localeCompare(b.tag || ''));
    await loadControls();
  } catch (err) {
    main.innerHTML = `<div class="page-head"><div><h1>Laptop control</h1></div></div><div class="err">${esc(err.message || String(err))}</div>`;
    return;
  }
  paint(main);
}

function paint(main) {
  const focusId = document.activeElement?.id;
  const caret = document.activeElement?.selectionStart;
  const rows = filtered();
  const counts = { standard: 0, elevated: 0, standing: 0, hold: 0 };
  for (const a of ui.laptops) {
    const c = current(a);
    counts[liveAdmin(c)] += 1;
    if (c.hold) counts.hold += 1;
  }
  const selected = ui.laptops.find(a => a.id === ui.selected) || null;
  const policyFilter = Object.entries(POLICIES).map(([k, v]) => `<option value="${k}" ${ui.policy === k ? 'selected' : ''}>${esc(v.label)}</option>`).join('');

  main.innerHTML = `
    <div class="page-head">
      <div>
        <h1>Laptop control</h1>
        <p>${ui.laptops.length} company laptop${ui.laptops.length === 1 ? '' : 's'} from the asset register. A laptop stays a standard user until you grant a timed window.</p>
      </div>
    </div>
    <div class="note" style="margin-bottom:16px">
      These are the rules you would show the person using the laptop: who has admin rights, and which channels a labeled company file may leave through.
      This page records that decision. It does not record keystrokes, screenshots, or file contents. A visible agent on the laptop is what would enforce it.
    </div>
    ${ui.source === 'local' ? `
      <div class="err" style="margin-bottom:16px">
        <strong>Shared storage is not set up yet.</strong> Decisions stay in this browser until you run <span class="mono">supabase/laptop-control.sql</span> once in the Supabase SQL editor.
        <div class="row" style="margin-top:8px"><button type="button" class="btn sm" id="copy-sql">Copy the SQL</button></div>
      </div>` : ''}
    <div class="kpis kpis-4">
      <div class="card kpi"><div class="k-label">Laptops</div><div class="k-val">${ui.laptops.length}</div></div>
      <div class="card kpi"><div class="k-label">Temporary admin</div><div class="k-val">${counts.elevated}</div></div>
      <div class="card kpi"><div class="k-label">Standing admin</div><div class="k-val">${counts.standing}</div></div>
      <div class="card kpi"><div class="k-label">On hold</div><div class="k-val">${counts.hold}</div></div>
    </div>
    <div class="card" style="margin-bottom:16px">
      <div class="filters">
        <input id="cq" class="search" placeholder="Search tag, person, serial, site" value="${esc(ui.q)}" />
        <select id="f-admin">
          <option value="all" ${ui.admin === 'all' ? 'selected' : ''}>Any admin rights</option>
          <option value="standard" ${ui.admin === 'standard' ? 'selected' : ''}>Standard user</option>
          <option value="elevated" ${ui.admin === 'elevated' ? 'selected' : ''}>Temporary admin</option>
          <option value="standing" ${ui.admin === 'standing' ? 'selected' : ''}>Standing admin</option>
        </select>
        <select id="f-policy">
          <option value="all" ${ui.policy === 'all' ? 'selected' : ''}>Any data rules</option>
          ${policyFilter}
        </select>
      </div>
      ${rows.length ? `<div class="tbl-wrap"><table class="tbl"><thead><tr>
        <th>Tag</th><th>Laptop</th><th>Person</th><th>Site</th><th>Admin rights</th><th>Data rules</th><th>Hold</th>
      </tr></thead><tbody>
        ${rows.map(a => {
          const c = current(a);
          return `<tr class="clickable${a.id === ui.selected ? ' on' : ''}" data-id="${esc(a.id)}">
            <td><span class="tag">${esc(a.tag)}</span></td>
            <td class="desc">${esc(a.description || a.model || '')}</td>
            <td>${esc(a.assigned_to || '—')}</td>
            <td>${esc(a.site || '—')}</td>
            <td><span class="badge ${adminClass(c)}">${esc(adminText(c))}</span></td>
            <td>${esc(POLICIES[c.policy]?.label || c.policy)}</td>
            <td>${c.hold ? '<span class="badge st-under_repair">On hold</span>' : '<span class="muted">No</span>'}</td>
          </tr>`;
        }).join('')}
      </tbody></table></div>` : `<div class="empty">${ui.laptops.length ? 'No laptops match these filters.' : 'No laptop is in the register. A laptop is an asset whose tag contains /LAP/, or whose category says Laptop.'}</div>`}
    </div>
    ${selected ? detail(selected) : '<div class="note">Select a laptop to set admin rights, data-leaving rules, or a hold.</div>'}
    <div class="card" style="margin-top:16px">
      <div class="card-h"><h2>Decisions</h2><span class="muted">${ui.source === 'db' ? 'Shared with every admin' : 'This browser only'}</span></div>
      ${ui.events.length ? `<div class="tbl-wrap"><table class="tbl"><thead><tr><th>When</th><th>Laptop</th><th>Decision</th><th>By</th></tr></thead><tbody>
        ${ui.events.slice(0, 20).map(e => {
          const a = ui.laptops.find(x => x.id === e.asset_id);
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
  document.getElementById('f-admin').onchange = (e) => { ui.admin = e.target.value; paint(main); };
  document.getElementById('f-policy').onchange = (e) => { ui.policy = e.target.value; paint(main); };
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
  if (focusId === 'cq' || focusId === 'f-admin' || focusId === 'f-policy') {
    const el = document.getElementById(focusId);
    if (el) {
      el.focus();
      if (focusId === 'cq' && caret != null) el.setSelectionRange(caret, caret);
    }
  }
}

function detail(a) {
  const c = current(a);
  const policy = POLICIES[c.policy] || POLICIES.baseline;
  const options = Object.entries(POLICIES).map(([k, v]) => `<option value="${k}" ${c.policy === k ? 'selected' : ''}>${esc(v.label)}</option>`).join('');
  return `<div class="card">
    <div class="card-h">
      <h2><span class="tag">${esc(a.tag)}</span> ${esc(a.description || a.model || 'Laptop')}</h2>
      <a href="#/asset/${esc(a.id)}">Open asset</a>
    </div>
    <div class="card-b stack">
      <div class="muted">${esc(a.assigned_to || 'Unassigned')}${a.department ? ' · ' + esc(a.department) : ''}${a.site ? ' · ' + esc(a.site) : ''}${a.serial_no ? ' · ' + esc(a.serial_no) : ''}</div>
      <div>
        <h2 style="margin-bottom:8px">Admin rights</h2>
        <p class="muted" style="margin:0 0 10px">Standard user is the default. A timed window ends on its own. Standing admin needs a written reason and stays until you revoke it. A hold does not wipe the laptop.</p>
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
        <h2 style="margin-bottom:8px">Data leaving the laptop</h2>
        <label class="f" style="max-width:280px">Rule set
          <select id="policy">${options}</select>
        </label>
        <ul class="muted" style="margin:10px 0 0; padding-left:18px">
          ${policy.rules.map(r => `<li>${esc(r)}</li>`).join('')}
        </ul>
      </div>
      <div>
        <h2 style="margin-bottom:8px">Hold</h2>
        ${c.hold
          ? `<p style="margin:0 0 10px">On hold${c.hold_reason ? ': ' + esc(c.hold_reason) : ''}. The person should see this reason.</p><button type="button" class="btn sm" data-act="release">Release hold</button>`
          : '<p class="muted" style="margin:0 0 10px">A hold stops company use of the laptop until you release it. Write the reason the person will see.</p><button type="button" class="btn sm" data-act="hold">Place on hold</button>'}
      </div>
    </div>
  </div>`;
}

function bindDetail(main, asset) {
  document.getElementById('policy').onchange = async (e) => {
    const policy = e.target.value;
    try {
      await save(main, asset, { ...current(asset), policy }, 'policy', `Data rules set to ${POLICIES[policy].label}`);
    } catch (err) { toast(err.message || String(err), true); }
  };
  main.querySelectorAll('[data-act]').forEach(btn => {
    btn.onclick = () => act(main, asset, btn.dataset.act);
  });
}

async function act(main, asset, kind) {
  const c = current(asset);
  try {
    if (kind === 'standard') {
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
        body: `<label class="f">Reason the person and the next admin can read<textarea name="reason" required placeholder="Why this laptop needs admin rights that do not expire"></textarea></label>`,
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
        submit: 'Hold laptop',
        danger: true,
        body: `<p style="margin:0">The person should be able to read this reason. A hold does not wipe the laptop.</p>
          <label class="f">Reason<textarea name="reason" required placeholder="Why company use of this laptop is paused"></textarea></label>`,
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
