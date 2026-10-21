/**
 * Next Move India — LMS <-> Google Sheet sync
 * Paste this whole file into the sheet: Extensions > Apps Script.
 *
 * What it does
 *  1. New website enquiries (tab "Sheet1") are sent into the LMS automatically.
 *  2. Every LMS lead is mirrored into a tab called "LMS Leads".
 *  3. Changes you type into the white columns of "LMS Leads" (status, follow-up,
 *     counselor, notes ...) are sent back into the LMS within seconds.
 *  4. If the same lead was changed in the LMS in the meantime, the LMS version
 *     wins and your sheet cell is refreshed (nothing is lost silently: you get a message).
 */

var DEFAULT_URL = 'https://qsibsuhejremcbzpmhwt.supabase.co';
// Public "publishable" key: safe to keep here. The private sync password is NOT stored in this file.
var DEFAULT_KEY = 'sb_publishable_xUiOIEr5U88-8DfQorcuWw_siREim5y';

var LEADS_TAB = 'LMS Leads';
var WEBSITE_TAB = 'Sheet1';
var TZ = 'Asia/Kolkata';
var QUIET_AFTER_EDIT_MS = 2 * 60 * 1000;

// header text, LMS field, editable in the sheet?
var COLS = [
  ['Lead ID', 'id', false],
  ['Received', 'created_at', false],
  ['Parent', 'parent_name', false],
  ['Phone', 'phone', false],
  ['Child', 'child_name', false],
  ['Age', 'child_age', false],
  ['City', 'city', false],
  ['Course', 'interested_course', true],
  ['Status', 'status', true],
  ['Counselor (email)', 'assigned_email', true],
  ['Next follow-up (YYYY-MM-DD)', 'next_follow_up', true],
  ['Demo date', 'demo_date', true],
  ['Demo time', 'demo_time', true],
  ['Notes', 'notes', true],
  ['Lost reason', 'lost_reason', true],
  ['Synced version (do not edit)', 'updated_at', false]
];

var STATUS_LABELS = {
  new: 'New', contacted: 'Contacted', interested: 'Interested', call_back_later: 'Call back later',
  demo_scheduled: 'Demo scheduled', demo_rescheduled: 'Demo rescheduled', demo_completed: 'Demo completed',
  follow_up: 'Follow-up (fee shared)', enrolled: 'Enrolled', not_interested: 'Not interested',
  not_reachable: 'Not reachable'
};

/* ---------------------------------------------------------------- menu */

function onOpen() {
  SpreadsheetApp.getUi().createMenu('Next Move LMS')
    .addItem('1. Connect to the LMS', 'connectToLms')
    .addItem('2. Sync now', 'syncAll')
    .addItem('3. Turn on automatic sync', 'turnOnAutoSync')
    .addItem('Turn off automatic sync', 'turnOffAutoSync')
    .addToUi();
}

function connectToLms() {
  var ui = SpreadsheetApp.getUi();
  var res = ui.prompt('Connect to the LMS', 'Paste the sync password you copied from Supabase:', ui.ButtonSet.OK_CANCEL);
  if (res.getSelectedButton() !== ui.Button.OK) return;
  var secret = String(res.getResponseText() || '').trim();
  if (!secret) { ui.alert('No password entered.'); return; }
  var props = PropertiesService.getScriptProperties();
  props.setProperty('SUPABASE_URL', DEFAULT_URL);
  props.setProperty('SUPABASE_KEY', DEFAULT_KEY);
  props.setProperty('SYNC_SECRET', secret);
  try {
    rpc_('sheet_leads_pull', {});
  } catch (err) {
    props.deleteProperty('SYNC_SECRET');
    ui.alert('Could not connect: ' + err.message + '\n\nCheck the password and try again.');
    return;
  }
  syncAll();
  ui.alert('Connected. Your leads are now in the "' + LEADS_TAB + '" tab.\n\nNext: Next Move LMS > 3. Turn on automatic sync.');
}

function turnOnAutoSync() {
  turnOffAutoSync();
  var ss = SpreadsheetApp.getActive();
  ScriptApp.newTrigger('onLmsEdit').forSpreadsheet(ss).onEdit().create();
  ScriptApp.newTrigger('syncAll').timeBased().everyMinutes(5).create();
  toast_('Automatic sync is on: edits go to the LMS within seconds, and the sheet refreshes every 5 minutes.');
}

function turnOffAutoSync() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    var fn = t.getHandlerFunction();
    if (fn === 'onLmsEdit' || fn === 'syncAll') ScriptApp.deleteTrigger(t);
  });
}

/* ---------------------------------------------------------- main syncs */

function syncAll() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) return;
  try {
    sendWebsiteLeads_();
    var last = Number(PropertiesService.getScriptProperties().getProperty('LAST_EDIT_MS') || 0);
    if (Date.now() - last > QUIET_AFTER_EDIT_MS) mirrorLeads_();
  } finally {
    lock.releaseLock();
  }
}

/** Fires when someone edits the sheet (installed trigger). */
function onLmsEdit(e) {
  if (!e || !e.range) return;
  var sheet = e.range.getSheet();
  if (sheet.getName() !== LEADS_TAB) return;
  var firstRow = e.range.getRow(), numRows = e.range.getNumRows();
  var firstCol = e.range.getColumn(), numCols = e.range.getNumColumns();
  if (firstRow + numRows - 1 < 2) return;                      // header only

  var editedFields = [];
  for (var c = firstCol; c < firstCol + numCols; c++) {
    var def = COLS[c - 1];
    if (def && def[2]) editedFields.push(def[1]);
  }
  var touchesNewRow = false;

  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) { toast_('The LMS is busy, please edit again in a moment.'); return; }
  try {
    var startRow = Math.max(2, firstRow);
    var count = firstRow + numRows - startRow;
    var values = sheet.getRange(startRow, 1, count, COLS.length).getValues();
    var rows = [];
    values.forEach(function (v) {
      var obj = rowToObject_(v);
      if (!obj.id) {
        if (!(obj.parent_name || obj.phone || obj.child_name)) return;   // empty row
        touchesNewRow = true;
        obj.status = labelToCode_(obj.status) || 'new';
        rows.push(stripEmpty_(obj));
        return;
      }
      if (!editedFields.length) return;
      var out = { id: obj.id, base_updated_at: obj.updated_at };
      editedFields.forEach(function (f) { out[f] = f === 'status' ? labelToCode_(obj[f]) : obj[f]; });
      rows.push(out);
    });
    if (!rows.length) return;

    PropertiesService.getScriptProperties().setProperty('LAST_EDIT_MS', String(Date.now()));
    var res = rpc_('sheet_leads_push', { p_rows: rows });
    if (touchesNewRow) mirrorLeads_(); else refreshRows_(sheet, startRow, count);

    var msg = (res.updated || 0) + ' saved to the LMS';
    if (res.conflicts) msg += ' · ' + res.conflicts + ' changed in the LMS meanwhile (sheet refreshed with the LMS version)';
    if (res.rejected) msg += ' · ' + res.rejected + ' not accepted (check status / counselor email / date format)';
    toast_(msg);
  } catch (err) {
    toast_('Could not save to the LMS: ' + err.message);
  } finally {
    lock.releaseLock();
  }
}

/* ------------------------------------------------ website form -> LMS */

function sendWebsiteLeads_() {
  var sheet = SpreadsheetApp.getActive().getSheetByName(WEBSITE_TAB);
  if (!sheet) return;
  var props = PropertiesService.getScriptProperties();
  var lastRow = lastDataRow_(sheet);
  var from = Number(props.getProperty('WEB_LAST_ROW') || 1) + 1;
  if (lastRow < from) return;

  var header = sheet.getRange(1, 1, 1, Math.max(9, sheet.getLastColumn())).getValues()[0];
  var map = websiteColumns_(header);
  var sentUpTo = from - 1;
  for (var start = from; start <= lastRow; start += 200) {
    var n = Math.min(200, lastRow - start + 1);
    var data = sheet.getRange(start, 1, n, header.length).getValues();
    var rows = [];
    data.forEach(function (r) {
      var o = websiteRowToLead_(r, map);
      if (o) rows.push(o);
    });
    if (rows.length) rpc_('sheet_leads_push', { p_rows: rows });
    sentUpTo = start + n - 1;
    props.setProperty('WEB_LAST_ROW', String(sentUpTo));
  }
}

function websiteColumns_(header) {
  var norm = header.map(function (h) { return String(h || '').toLowerCase().replace(/[^a-z0-9]/g, ''); });
  function find(names, fallback) {
    for (var i = 0; i < norm.length; i++) for (var j = 0; j < names.length; j++) if (norm[i] === names[j]) return i;
    return fallback;
  }
  var ts = 0;
  for (var k = 0; k < norm.length; k++) if (norm[k].indexOf('timestamp') === 0) { ts = k; break; }
  return {
    ts: ts,
    parent: find(['parentsname', 'parentname', 'parent'], 1),
    phone: find(['mobileno', 'phone', 'mobile', 'phonenumber'], 2),
    child: find(['childsname', 'childname'], 3),
    age: find(['childsage', 'childage', 'age'], 4),
    city: find(['location', 'city'], 5),
    status: find(['status'], 6),
    demoDate: find(['demodate'], 7),
    demoTime: find(['demotime'], 8)
  };
}

function websiteRowToLead_(r, m) {
  var text = function (i) { var v = r[i]; return v === null || v === undefined ? '' : String(v).trim(); };
  var parent = text(m.parent), phone = text(m.phone), child = text(m.child);
  if (!parent && !phone && !child) return null;
  var tsRaw = r[m.ts];
  var iso = toIso_(tsRaw);
  var digits = phone.replace(/\D/g, '');
  return {
    sheet_key: (iso || text(m.ts)) + '|' + digits,
    created_at: iso,
    parent_name: parent, phone: phone, child_name: child,
    child_age: text(m.age), city: text(m.city),
    status: labelToCode_(text(m.status)) || 'new',
    demo_date: cellText_(r[m.demoDate]), demo_time: cellText_(r[m.demoTime])
  };
}

/* ------------------------------------------------------ LMS -> sheet */

function mirrorLeads_() {
  var sheet = ensureLeadsSheet_();
  var list = rpc_('sheet_leads_pull', {});
  var out = list.map(objectToRow_);
  if (out.length) sheet.getRange(2, 1, out.length, COLS.length).setValues(out);
  var last = sheet.getLastRow();
  if (last > out.length + 1) sheet.getRange(out.length + 2, 1, last - out.length - 1, COLS.length).clearContent();
}

function refreshRows_(sheet, startRow, count) {
  var list = rpc_('sheet_leads_pull', {});
  var byId = {};
  list.forEach(function (o) { byId[o.id] = o; });
  var range = sheet.getRange(startRow, 1, count, COLS.length);
  var current = range.getValues();
  var next = current.map(function (row) {
    var id = row[0];
    return id && byId[id] ? objectToRow_(byId[id]) : row;
  });
  range.setValues(next);
}

function ensureLeadsSheet_() {
  var ss = SpreadsheetApp.getActive();
  var sheet = ss.getSheetByName(LEADS_TAB);
  if (sheet) return sheet;
  sheet = ss.insertSheet(LEADS_TAB);
  sheet.getRange(1, 1, 1, COLS.length).setValues([COLS.map(function (c) { return c[0]; })]);
  sheet.getRange(1, 1, 1, COLS.length).setFontWeight('bold').setBackground('#ffedd5');
  sheet.getRange(2, 1, 2000, COLS.length).setNumberFormat('@');          // keep text exactly as typed
  sheet.setFrozenRows(1);
  var statusCol = indexOfField_('status') + 1;
  var labels = Object.keys(STATUS_LABELS).map(function (k) { return STATUS_LABELS[k]; });
  sheet.getRange(2, statusCol, 2000, 1).setDataValidation(
    SpreadsheetApp.newDataValidation().requireValueInList(labels, true).setAllowInvalid(false).build());
  COLS.forEach(function (c, i) {
    if (!c[2]) sheet.getRange(2, i + 1, 2000, 1).protect().setWarningOnly(true).setDescription('Managed by the LMS');
  });
  sheet.hideColumns(1);
  sheet.hideColumns(COLS.length);
  return sheet;
}

/* ------------------------------------------------------------ helpers */

function rpc_(fn, body) {
  var props = PropertiesService.getScriptProperties();
  var url = props.getProperty('SUPABASE_URL') || DEFAULT_URL;
  var key = props.getProperty('SUPABASE_KEY') || DEFAULT_KEY;
  var secret = props.getProperty('SYNC_SECRET');
  if (!secret) throw new Error('Not connected yet. Use Next Move LMS > 1. Connect to the LMS.');
  body.p_secret = secret;
  var resp = UrlFetchApp.fetch(url + '/rest/v1/rpc/' + fn, {
    method: 'post', contentType: 'application/json', headers: { apikey: key },
    payload: JSON.stringify(body), muteHttpExceptions: true
  });
  var code = resp.getResponseCode(), text = resp.getContentText();
  if (code < 200 || code >= 300) {
    var msg = text;
    try { var j = JSON.parse(text); msg = j.message || j.hint || text; } catch (e) { /* keep raw text */ }
    throw new Error(code === 400 && /unauthorized/i.test(msg) ? 'wrong sync password' : msg);
  }
  return JSON.parse(text);
}

function indexOfField_(field) {
  for (var i = 0; i < COLS.length; i++) if (COLS[i][1] === field) return i;
  return -1;
}

function rowToObject_(v) {
  var o = {};
  COLS.forEach(function (c, i) { o[c[1]] = cellText_(v[i]); });
  return o;
}

function objectToRow_(o) {
  return COLS.map(function (c) {
    var val = o[c[1]];
    if (val === null || val === undefined) return '';
    if (c[1] === 'status') return STATUS_LABELS[val] || val;
    if (c[1] === 'created_at') return toDisplayDate_(val);
    return String(val);
  });
}

function stripEmpty_(obj) {
  var out = {};
  Object.keys(obj).forEach(function (k) { if (obj[k] !== '' && k !== 'updated_at' && k !== 'id') out[k] = obj[k]; });
  return out;
}

function labelToCode_(text) {
  var t = String(text || '').trim().toLowerCase();
  if (!t) return '';
  if (STATUS_LABELS[t]) return t;
  var keys = Object.keys(STATUS_LABELS);
  for (var i = 0; i < keys.length; i++) if (STATUS_LABELS[keys[i]].toLowerCase() === t) return keys[i];
  var slug = t.replace(/^[\d.\s]+/, '').replace(/[^a-z]+/g, '_').replace(/^_|_$/g, '');
  if (STATUS_LABELS[slug]) return slug;
  var alias = { new_inquiry: 'new', fee_shared_follow_up: 'follow_up', fee_shared: 'follow_up',
    not_interested_lost: 'not_interested', lost: 'not_interested', demo_done: 'demo_completed',
    rescheduled: 'demo_rescheduled', demo_booked: 'demo_scheduled' };
  return alias[slug] || '';
}

function cellText_(v) {
  if (v === null || v === undefined) return '';
  if (Object.prototype.toString.call(v) === '[object Date]') {
    return Utilities.formatDate(v, TZ, v.getHours() + v.getMinutes() + v.getSeconds() === 0 ? 'yyyy-MM-dd' : 'HH:mm');
  }
  return String(v).trim();
}

function toIso_(v) {
  if (!v) return '';
  if (Object.prototype.toString.call(v) === '[object Date]') return Utilities.formatDate(v, TZ, "yyyy-MM-dd'T'HH:mm:ssXXX");
  var m = String(v).trim().match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})(?:\s+(\d{1,2}):(\d{2})(?::(\d{2}))?)?$/);
  if (!m) return '';
  var p = function (n) { return ('0' + (n || 0)).slice(-2); };
  return m[3] + '-' + p(m[2]) + '-' + p(m[1]) + 'T' + p(m[4]) + ':' + p(m[5]) + ':' + p(m[6]) + '+05:30';
}

function toDisplayDate_(iso) {
  var d = new Date(iso);
  if (isNaN(d.getTime())) return String(iso);
  return Utilities.formatDate(d, TZ, 'yyyy-MM-dd HH:mm');
}

function lastDataRow_(sheet) {
  var n = sheet.getLastRow();
  if (n < 2) return n;
  var col = sheet.getRange(1, 1, n, 1).getValues();
  for (var i = n - 1; i >= 1; i--) if (String(col[i][0]).trim() !== '') return i + 1;
  return 1;
}

function toast_(msg) {
  try { SpreadsheetApp.getActive().toast(msg, 'Next Move LMS', 6); } catch (e) { /* no UI (timed run) */ }
}
