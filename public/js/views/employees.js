import { esc, icon, toast, modal, datalist, $, $$ } from '../ui.js';
import {
  store, loadAssets, invalidate, distinct, personKey, peopleFromAssets, assetsForPerson,
  syncAssignedEmployees, STATUS,
} from '../data.js';

const blank = (row = {}) => ({
  id: null,
  name: '',
  email: '',
  department: '',
  site: '',
  phone: '',
  job_title: '',
  employee_code: '',
  notes: '',
  active: true,
  origin: 'manual',
  ...row,
});

function virtualRows(assets) {
  return peopleFromAssets(assets).map(p => blank({
    name: p.name,
    department: p.department,
    site: p.site,
    origin: 'asset',
  }));
}

function formBody(row, assets, rows) {
  const depts = mergeList(distinct('department', assets), rows.map(r => r.department));
  const sites = mergeList(distinct('site', assets), rows.map(r => r.site));
  const held = assetsForPerson(assets, row.name);
  return `
    <div class="form-grid">
      <label class="f wide">Name <span class="req">*</span><input name="name" required autocomplete="off" value="${esc(row.name)}"></label>
      <label class="f">Work e-mail<input name="email" type="email" autocomplete="off" value="${esc(row.email || '')}"></label>
      <label class="f">Employee code<input name="employee_code" autocomplete="off" value="${esc(row.employee_code || '')}"></label>
      <label class="f">Department<input name="department" list="dl-emp-dept" autocomplete="off" value="${esc(row.department || '')}"></label>
      <label class="f">Site<input name="site" list="dl-emp-site" autocomplete="off" value="${esc(row.site || '')}"></label>
      <label class="f">Job title<input name="job_title" autocomplete="off" value="${esc(row.job_title || '')}"></label>
      <label class="f">Phone<input name="phone" autocomplete="off" value="${esc(row.phone || '')}"></label>
      <label class="f wide">Notes<textarea name="notes">${esc(row.notes || '')}</textarea></label>
      <label class="check"><input type="checkbox" name="active" ${row.active === false ? '' : 'checked'}> Active</label>
    </div>
    ${datalist('dl-emp-dept', depts)}
    ${datalist('dl-emp-site', sites)}
    ${held.length ? `<p class="note" style="margin:0">Currently holds ${held.length} asset${held.length === 1 ? '' : 's'}. A new name is written onto those assets. Checking equipment back in still happens on each asset.</p>` : ''}`;
}

function mergeList(a, b) {
  const m = new Map();
  for (const raw of [...a, ...b]) {
    const v = String(raw || '').trim();
    if (!v) continue;
    const k = v.toLowerCase();
    if (!m.has(k)) m.set(k, v);
  }
  return [...m.values()].sort((x, y) => x.localeCompare(y));
}

function field(form, name) {
  return String(new FormData(form).get(name) || '').trim();
}

function readForm(form) {
  const name = field(form, 'name');
  const email = field(form, 'email');
  if (!name) throw new Error('Enter the employee name.');
  if (email && !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) throw new Error('Enter a valid e-mail address, or leave it blank.');
  return {
    name,
    email: email || null,
    department: field(form, 'department') || null,
    site: field(form, 'site') || null,
    phone: field(form, 'phone') || null,
    job_title: field(form, 'job_title') || null,
    employee_code: field(form, 'employee_code') || null,
    notes: field(form, 'notes') || null,
    active: Boolean(form.elements.active?.checked),
  };
}

export async function employeesView(main, params) {
  main.innerHTML = '<div class="muted" style="padding:20px 0">Loading…</div>';
  const assets = await loadAssets();
  let storage = true;
  let added = 0;
  let rows = [];
  try {
    const synced = await syncAssignedEmployees(assets);
    storage = synced.storage;
    added = synced.added;
    rows = storage ? synced.rows.map(r => blank(r)) : virtualRows(assets);
  } catch (err) {
    main.innerHTML = `<div class="err">Could not load employees: ${esc(err.message)}</div>`;
    return;
  }
  if (storage) {
    const have = new Set(rows.map(r => personKey(r.name)));
    for (const extra of virtualRows(assets)) {
      if (!have.has(personKey(extra.name))) rows.push(extra);
    }
  }
  rows.sort((a, b) => a.name.localeCompare(b.name));

  const state = { q: params.q || '', who: params.who || 'all', open: params.person || '' };

  function held(name) { return assetsForPerson(assets, name); }
  function filtered() {
    const words = state.q.toLowerCase().split(/\s+/).filter(Boolean);
    return rows.filter(r => {
      const n = held(r.name).length;
      if (state.who === 'assigned' && !n) return false;
      if (state.who === 'unassigned' && n) return false;
      if (state.who === 'inactive' && r.active !== false) return false;
      if (!words.length) return true;
      const hay = [r.name, r.email, r.department, r.site, r.job_title, r.employee_code, r.phone].join(' ').toLowerCase();
      return words.every(w => hay.includes(w));
    });
  }

  function render() {
    const list = filtered();
    const focus = rows.find(r => personKey(r.name) === personKey(state.open));
    const focusAssets = focus ? held(focus.name) : [];
    main.innerHTML = `
      <div class="page-head">
        <div>
          <h1>Employees</h1>
          <p>Add someone before they receive a laptop, or correct a name already on the register. Anyone an asset is assigned to is included automatically.</p>
        </div>
        <button class="btn primary" id="add">${icon('plus')} Add employee</button>
      </div>
      ${storage ? '' : `<div class="note" style="margin:0 0 12px">People assigned to assets are listed below. To save new employees and edits, run <span class="mono">supabase/employees.sql</span> once in the Supabase SQL editor, then refresh this page.</div>`}
      ${added ? `<div class="note" style="margin:0 0 12px">${added} ${added === 1 ? 'person' : 'people'} assigned to assets ${added === 1 ? 'was' : 'were'} added to the employee list.</div>` : ''}
      <div class="card">
        <div class="filters" style="grid-template-columns:minmax(200px,1fr) 180px">
          <input type="search" class="search" id="q" placeholder="Search name, e-mail, department, code…" value="${esc(state.q)}">
          <select id="who" aria-label="Which employees">
            <option value="all" ${state.who === 'all' ? 'selected' : ''}>Everyone</option>
            <option value="assigned" ${state.who === 'assigned' ? 'selected' : ''}>Has assets</option>
            <option value="unassigned" ${state.who === 'unassigned' ? 'selected' : ''}>No assets yet</option>
            <option value="inactive" ${state.who === 'inactive' ? 'selected' : ''}>Inactive</option>
          </select>
        </div>
        ${list.length ? `<div class="tbl-wrap"><table class="tbl"><thead><tr>
            <th>Name</th><th>Department</th><th>Site</th><th>E-mail</th><th>Assets</th><th></th>
          </tr></thead><tbody>
          ${list.map(r => {
            const n = held(r.name).length;
            return `<tr>
              <td><button class="btn ghost sm" data-open="${esc(r.name)}" style="padding-left:0">${esc(r.name)}</button>
                <div class="sub">${esc([r.job_title, r.employee_code].filter(Boolean).join(' · '))}${r.active === false ? ' <span class="badge">Inactive</span>' : ''}${r.origin === 'asset' ? ' <span class="muted">From an asset</span>' : ''}</div></td>
              <td>${esc(r.department || '')}</td>
              <td>${esc(r.site || '')}</td>
              <td>${esc(r.email || '')}</td>
              <td>${n ? `<button class="btn ghost sm" data-open="${esc(r.name)}">${n}</button>` : '<span class="muted">0</span>'}</td>
              <td style="text-align:right"><button class="btn sm" data-edit="${esc(r.name)}">${icon('edit')} Edit</button></td>
            </tr>`;
          }).join('')}
          </tbody></table></div>
          <div class="tbl-foot"><span>${list.length} of ${rows.length}</span></div>`
        : '<div class="empty">No employees match. Add someone, or check an asset out to a person and they will show up here.</div>'}
      </div>
      ${focus ? `<div class="card" style="margin-top:16px">
        <div class="card-h"><h2>${esc(focus.name)}</h2><button class="btn sm" data-edit="${esc(focus.name)}">${icon('edit')} Edit</button></div>
        <div class="card-b">
          ${focusAssets.length ? `<div class="tbl-wrap"><table class="tbl"><thead><tr><th>Tag</th><th>Description</th><th>Status</th><th>Department</th><th>Site</th></tr></thead><tbody>
            ${focusAssets.map(a => `<tr class="clickable" data-href="#/asset/${a.id}">
              <td class="tag">${esc(a.tag)}</td>
              <td>${esc(a.description || '')}</td>
              <td><span class="badge st-${a.status}">${STATUS[a.status]?.label || esc(a.status)}</span></td>
              <td>${esc(a.department || '')}</td>
              <td>${esc(a.site || '')}</td>
            </tr>`).join('')}
          </tbody></table></div>` : '<p class="muted" style="margin:0">No asset is assigned to this person right now.</p>'}
        </div>
      </div>` : ''}`;

    const syncHash = () => {
      const p = {};
      if (state.q) p.q = state.q;
      if (state.who && state.who !== 'all') p.who = state.who;
      if (state.open) p.person = state.open;
      const qs = new URLSearchParams(p).toString();
      history.replaceState(null, '', '#/employees' + (qs ? '?' + qs : ''));
    };
    let t;
    $('#q').oninput = (e) => { clearTimeout(t); t = setTimeout(() => { state.q = e.target.value.trim(); syncHash(); render(); }, 150); };
    $('#who').onchange = (e) => { state.who = e.target.value; syncHash(); render(); };
    $('#add').onclick = () => openForm(blank());
    $$('[data-edit]').forEach(b => b.onclick = () => {
      const row = rows.find(r => r.name === b.dataset.edit);
      if (row) openForm(row);
    });
    $$('[data-open]').forEach(b => b.onclick = () => {
      state.open = state.open === b.dataset.open ? '' : b.dataset.open;
      syncHash();
      render();
    });
    $$('#main tr[data-href], .card tr[data-href]').forEach(tr => tr.onclick = () => { location.hash = tr.dataset.href; });
  }

  async function openForm(row) {
    if (!storage) {
      toast('Run supabase/employees.sql in Supabase before saving employees.', true);
    }
    const isNew = !row.name;
    let savedName = row.name;
    const ok = await modal({
      title: isNew ? 'Add employee' : `Edit ${row.name}`,
      submit: isNew ? 'Add employee' : 'Save',
      body: formBody(row, assets, rows),
      onSubmit: async (form) => {
        if (!storage) throw new Error('Run supabase/employees.sql once in the Supabase SQL editor, then refresh this page.');
        const next = readForm(form);
        const clash = rows.find(r => personKey(r.name) === personKey(next.name) && r.id !== row.id);
        if (clash) throw new Error(`${next.name} is already on the employee list.`);
        if (row.id) {
          await store.db.update('employees', { id: 'eq.' + row.id }, next);
        } else {
          try {
            await store.db.insert('employees', [{ ...next, origin: row.origin === 'asset' ? 'asset' : 'manual' }]);
          } catch (err) {
            throw new Error(/duplicate|unique/i.test(err.message) ? `${next.name} is already on the employee list.` : err.message);
          }
        }
        await applyToAssets(row, next);
        savedName = next.name;
      },
    });
    if (ok) {
      invalidate();
      toast(isNew ? 'Employee added' : 'Employee saved');
      const person = personKey(state.open) === personKey(row.name) ? savedName : state.open;
      employeesView(main, { q: state.q, who: state.who, person });
    }
  }

  async function applyToAssets(oldRow, next) {
    if (!oldRow.name) return;
    const affected = assets.filter(a => personKey(a.assigned_to) === personKey(oldRow.name));
    const deptChanged = String(oldRow.department || '') !== String(next.department || '');
    const siteChanged = String(oldRow.site || '') !== String(next.site || '');
    const nameChanged = oldRow.name !== next.name;
    for (const a of affected) {
      const patch = {};
      if (nameChanged) patch.assigned_to = next.name;
      if (deptChanged && (!String(a.department || '').trim() || personKey(a.department) === personKey(oldRow.department))) {
        patch.department = next.department;
      }
      if (siteChanged && (!String(a.site || '').trim() || personKey(a.site) === personKey(oldRow.site))) {
        patch.site = next.site;
      }
      if (!Object.keys(patch).length) continue;
      await store.db.update('assets', { id: 'eq.' + a.id }, patch);
      const note = nameChanged
        ? `Employee renamed from ${oldRow.name} to ${next.name}`
        : `Employee ${next.name} updated`;
      await store.db.insert('asset_events', [{
        asset_id: a.id,
        action: 'edited',
        from_status: a.status,
        to_status: a.status,
        assigned_to: next.name,
        department: patch.department ?? a.department ?? null,
        site: patch.site ?? a.site ?? null,
        notes: note,
      }]);
    }
  }

  render();
}
