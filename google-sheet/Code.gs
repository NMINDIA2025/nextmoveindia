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
 *  5. Students, Teachers, Classes, Materials, Tasks, Payments and Attendance each get
 *     their own "LMS ..." tab that works the same way, in both directions. You can add
 *     new rows (leave the hidden ID cell empty) for Students, Teachers, Classes,
 *     Materials and Tasks.
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


/* Extra tabs: header, LMS field, editable in the sheet?, optional dropdown list.
   Column A is always the hidden ID and the last column the hidden "synced version". */
var TABS = {
  'LMS Students': { table: 'students', insert: true, cols: [
    ['Student ID', 'student_code', false], ['Name', 'full_name', true], ['Age', 'age', true],
    ['Course', 'course_name', true], ['Batch timings', 'batch_timings', true],
    ['Sessions done', 'sessions_completed', true], ['Total sessions', 'total_sessions', true],
    ['Progress %', 'progress_percent', false], ['Status', 'status', true, ['active', 'on_hold', 'completed', 'discontinued']],
    ['Joined (YYYY-MM-DD)', 'joined_at', true], ['Parent email (their login)', 'parent_email', true],
    ['Progress notes', 'progress_notes', true]] },
  'LMS Teachers': { table: 'teachers', insert: true, cols: [
    ['Name', 'full_name', true], ['Email', 'email', true], ['Phone', 'phone', true],
    ['Speciality', 'subject', true], ['Status', 'status', true, ['active', 'inactive']]] },
  'LMS Classes': { table: 'classes', insert: true, cols: [
    ['Title', 'title', true], ['Course', 'course_name', true], ['Teacher (name)', 'teacher_name', true],
    ['Type', 'kind', true, ['batch', 'demo', 'one_to_one', 'workshop']],
    ['Date (YYYY-MM-DD)', 'class_date', true], ['Time', 'class_time', true], ['Minutes', 'duration_min', true],
    ['Meet link', 'meet_link', true], ['Recording link', 'recording_url', true],
    ['Status', 'status', true, ['scheduled', 'completed', 'cancelled']],
    ['Notes', 'notes', true]] },
  'LMS Materials': { table: 'materials', insert: true, cols: [
    ['Title', 'title', true], ['Course', 'course_name', true],
    ['Type', 'kind', true, ['video', 'pdf', 'worksheet', 'slides', 'quiz', 'game', 'link']],
    ['Link (Drive / YouTube)', 'url', true], ['Age group', 'age_group', true], ['Language', 'language', true, ['English', 'Hindi', 'Both']],
    ['Description', 'description', true], ['Visible to families', 'published', true, ['TRUE', 'FALSE']], ['Order', 'sort_order', true]] },
  'LMS Tasks': { table: 'tasks', insert: true, cols: [
    ['Task', 'title', true], ['Details', 'description', true], ['Priority', 'priority', true, ['low', 'normal', 'high']],
    ['Status', 'status', true, ['todo', 'doing', 'done']], ['Due (YYYY-MM-DD)', 'due_date', true],
    ['Assigned to (name)', 'assignee_name', true]] },
  'LMS Payments': { table: 'payments', insert: false, cols: [
    ['Student', 'student_name', false], ['Course', 'course_name', true], ['Package', 'package', true],
    ['Amount', 'amount', true], ['Due (YYYY-MM-DD)', 'due_date', true], ['Paid on (YYYY-MM-DD)', 'paid_date', true],
    ['Status', 'status', true, ['pending', 'paid', 'overdue', 'cancelled']]] },
  'LMS Assignments': { table: 'assignments', insert: true, cols: [
    ['Title', 'title', true], ['Instructions', 'instructions', true], ['Course (blank = all)', 'course_name', true],
    ['Due (YYYY-MM-DD)', 'due_date', true], ['Answer by', 'answer_type', true, ['both', 'link', 'text']],
    ['Visible to families', 'published', true, ['TRUE', 'FALSE']]] },
  'LMS Submissions': { table: 'submissions', insert: false, cols: [
    ['Student', 'student_name', false], ['Assignment', 'assignment_title', false], ['Answer', 'answer_text', false],
    ['Link', 'answer_link', false], ['Status', 'status', false], ['Feedback', 'feedback', true], ['Grade', 'grade', true]] },
  'LMS Attendance': { table: 'attendance', insert: false, cols: [
    ['Date', 'class_date', false], ['Class', 'class_title', false], ['Student', 'student_name', false],
    ['Status', 'status', true, ['present', 'absent', 'late', 'excused']], ['Note', 'note', true]] }
};

/* ---------------------------------------------------------------- menu */

function onOpen() {
  SpreadsheetApp.getUi().createMenu('Next Move LMS')
    .addItem('1. Connect to the LMS', 'connectToLms')
    .addItem('2. Sync now', 'syncAll')
    .addItem('3. Turn on automatic sync', 'turnOnAutoSync')
    .addItem('Create Meet links + Calendar events now', 'createMeetLinksNow')
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
  ui.alert('Connected. Your leads are in the "' + LEADS_TAB + '" tab, and Students, Classes, Materials, Tasks, Teachers, Payments and Attendance each have an "LMS ..." tab.\n\nNext: Next Move LMS > 3. Turn on automatic sync.');
}

function turnOnAutoSync() {
  turnOffAutoSync();
  var ss = SpreadsheetApp.getActive();
  ScriptApp.newTrigger('onLmsEdit').forSpreadsheet(ss).onEdit().create();
  ScriptApp.newTrigger('syncAll').timeBased().everyMinutes(5).create();
  ScriptApp.newTrigger('calendarTick').timeBased().everyMinutes(1).create();   // Meet links appear within ~1 minute
  toast_('Automatic sync is on: edits go to the LMS within seconds, the sheet refreshes every 5 minutes, and Meet links / Calendar events are made every minute.');
}

function turnOffAutoSync() {
  ScriptApp.getProjectTriggers().forEach(function (t) {
    var fn = t.getHandlerFunction();
    if (fn === 'onLmsEdit' || fn === 'syncAll' || fn === 'calendarTick') ScriptApp.deleteTrigger(t);
  });
}

/* ---------------------------------------------------------- main syncs */

function syncAll() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) return;
  try {
    sendWebsiteLeads_();
    try { syncCalendar_(); } catch (err) { toast_('Calendar / Meet: ' + err.message); }
    var last = Number(PropertiesService.getScriptProperties().getProperty('LAST_EDIT_MS') || 0);
    if (Date.now() - last > QUIET_AFTER_EDIT_MS) {
      mirrorLeads_();
      var problems = [];
      Object.keys(TABS).forEach(function (name) {
        try { mirrorTab_(name); } catch (err) { problems.push(name + ': ' + err.message); }
      });
      if (problems.length) toast_('Some tabs could not refresh. ' + problems[0]);
    }
  } finally {
    lock.releaseLock();
  }
}

/** Fires when someone edits the sheet (installed trigger). */
function onLmsEdit(e) {
  if (!e || !e.range) return;
  var sheet = e.range.getSheet();
  if (TABS[sheet.getName()]) return onTabEdit_(e, sheet, TABS[sheet.getName()]);
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



/* ------------------------------ Google Calendar + Meet for every class */
/* Needs: Apps Script > Services (+) > "Google Calendar API" > Add (once). */

var CAL_ID = 'primary';

function createMeetLinksNow() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) return;
  try {
    var r = syncCalendar_();
    toast_('Calendar: ' + r.created + ' added, ' + r.updated + ' updated, ' + r.cancelled + ' cancelled · ' + r.linkOnly + ' Meet link(s) made for classes still to be confirmed · ' + (r.series || 0) + ' course schedule(s) updated');
  } catch (err) {
    SpreadsheetApp.getUi().alert('Could not create Calendar events:\n\n' + err.message);
  } finally { lock.releaseLock(); }
}

/** Runs every minute (separate from the full sync) so a new demo gets its Meet link quickly. */
function calendarTick() {
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(3000)) return;
  try { syncCalendar_(); }
  catch (err) { PropertiesService.getScriptProperties().setProperty('CAL_LAST_ERROR', String(err.message || err)); }
  finally { lock.releaseLock(); }
}

/** A "pending" calendar holds Meet links for classes whose date/time is not confirmed yet. */
function pendingCalendarId_() {
  var props = PropertiesService.getScriptProperties();
  var id = props.getProperty('PENDING_CAL');
  if (id) return id;
  var cal = Calendar.Calendars.insert({ summary: 'Next Move – demo links (time not confirmed)', timeZone: TZ });
  props.setProperty('PENDING_CAL', cal.id);
  return cal.id;
}

/**
 * For every scheduled class:
 *  - Step 1 (as soon as the class exists): a Google Meet link is created and written into the LMS.
 *    It lives in a hidden-style "pending" calendar, so your main calendar stays clean.
 *  - Step 2 (once date AND time are confirmed): the event moves to your main calendar with the
 *    same Meet link, and the teacher and parent are invited.
 *  - Later changes to the date/time/title/guests update the event; cancelling removes it.
 */
function syncCalendar_() {
  if (typeof Calendar === 'undefined') {
    throw new Error('Turn on the Google Calendar service first: Apps Script > Services (+ icon) > Google Calendar API > Add.');
  }
  var props = PropertiesService.getScriptProperties();
  var sigs = JSON.parse(props.getProperty('CAL_SIGS') || '{}');
  var pending = JSON.parse(props.getProperty('CAL_PENDING') || '{}');
  var guests = {};
  rpc_('sheet_class_guests', {}).forEach(function (g) { guests[g.id] = g.emails || []; });
  var classes = rpc_('sheet_table_pull', { p_table: 'classes' });
  var inSchedule = {};
  try { rpc_('sheet_class_nocal', {}).forEach(function (id) { inSchedule[id] = 1; }); } catch (e) { /* older database: no schedules yet */ }
  classes = classes.filter(function (c) { return !inSchedule[c.id]; });
  var out = { created: 0, updated: 0, cancelled: 0, linkOnly: 0, series: 0 };
  var title = function (c) { return c.title || 'Next Move India class'; };
  var desc = 'Next Move India class. Join from the LMS: https://nextmoveindia.org/lms/';
  var newMeet = function () { return { createRequest: { requestId: Utilities.getUuid(), conferenceSolutionKey: { type: 'hangoutsMeet' } } }; };

  classes.forEach(function (c) {
    var evId = c.calendar_event_id || '';
    var isPending = !!pending[c.id];
    var calOf = function () { return isPending ? pendingCalendarId_() : CAL_ID; };

    if (c.status === 'cancelled') {
      if (evId) {
        try { Calendar.Events.remove(calOf(), evId, { sendUpdates: isPending ? 'none' : 'all' }); } catch (e) { /* already gone */ }
        saveClass_(c.id, { calendar_event_id: '' });
        delete sigs[c.id]; delete pending[c.id]; out.cancelled++;
      }
      return;
    }
    if (c.status !== 'scheduled') return;

    var when = classWhen_(c);
    var emails = cleanEmails_(guests[c.id]);
    var attendees = emails.map(function (m) { return { email: m }; });

    /* ---- no event yet ---- */
    if (!evId) {
      if (c.meet_link) return;                              // you typed your own link: leave it alone
      if (when) {                                           // confirmed: straight onto the main calendar
        var ev = Calendar.Events.insert({
          summary: title(c), description: desc, attendees: attendees, conferenceData: newMeet(),
          start: { dateTime: when.start, timeZone: TZ }, end: { dateTime: when.end, timeZone: TZ }
        }, CAL_ID, { conferenceDataVersion: 1, sendUpdates: 'all' });
        saveClass_(c.id, { calendar_event_id: ev.id, meet_link: meetLink_(ev) });
        sigs[c.id] = JSON.stringify([title(c), when.start, when.end, emails]); out.created++;
      } else {                                              // not confirmed: make the Meet link only
        var t0 = new Date(Date.now() + 24 * 3600 * 1000);
        var ph = Utilities.formatDate(t0, TZ, "yyyy-MM-dd'T'09:00:00XXX");
        var phEnd = Utilities.formatDate(t0, TZ, "yyyy-MM-dd'T'09:30:00XXX");
        var pev = Calendar.Events.insert({
          summary: '⏳ ' + title(c) + ' (time to be confirmed)', description: desc, conferenceData: newMeet(),
          start: { dateTime: ph, timeZone: TZ }, end: { dateTime: phEnd, timeZone: TZ }
        }, pendingCalendarId_(), { conferenceDataVersion: 1, sendUpdates: 'none' });
        saveClass_(c.id, { calendar_event_id: pev.id, meet_link: meetLink_(pev) });
        pending[c.id] = 1; out.linkOnly++;
      }
      return;
    }

    /* ---- event exists, but its Meet link was not ready earlier ---- */
    if (!c.meet_link) {
      try { var got = Calendar.Events.get(calOf(), evId); var l = meetLink_(got); if (l) saveClass_(c.id, { meet_link: l }); } catch (e) { /* retry next time */ }
    }

    /* ---- pending -> confirmed: move to the main calendar, keep the same link ---- */
    if (isPending) {
      if (!when) return;
      var moved = null;
      try { moved = Calendar.Events.move(pendingCalendarId_(), evId, CAL_ID, { sendUpdates: 'none' }); } catch (e) { moved = null; }
      var keep = moved && meetLink_(moved) ? moved : null;
      if (keep) {
        Calendar.Events.patch({
          summary: title(c), description: desc, attendees: attendees,
          start: { dateTime: when.start, timeZone: TZ }, end: { dateTime: when.end, timeZone: TZ }
        }, CAL_ID, evId, { sendUpdates: 'all', conferenceDataVersion: 1 });
        out.updated++;
      } else {                                              // could not move: create fresh (new Meet link) and drop the pending one
        try { Calendar.Events.remove(pendingCalendarId_(), evId, { sendUpdates: 'none' }); } catch (e) { /* ignore */ }
        var fresh = Calendar.Events.insert({
          summary: title(c), description: desc, attendees: attendees, conferenceData: newMeet(),
          start: { dateTime: when.start, timeZone: TZ }, end: { dateTime: when.end, timeZone: TZ }
        }, CAL_ID, { conferenceDataVersion: 1, sendUpdates: 'all' });
        saveClass_(c.id, { calendar_event_id: fresh.id, meet_link: meetLink_(fresh) });
        evId = fresh.id; out.created++;
      }
      delete pending[c.id];
      sigs[c.id] = JSON.stringify([title(c), when.start, when.end, emails]);
      return;
    }

    /* ---- confirmed event: keep it in step with the LMS ---- */
    if (!when) return;
    var sig = JSON.stringify([title(c), when.start, when.end, emails]);
    if (sigs[c.id] === undefined) { sigs[c.id] = sig; return; }
    if (sigs[c.id] !== sig) {
      Calendar.Events.patch({
        summary: title(c), start: { dateTime: when.start, timeZone: TZ }, end: { dateTime: when.end, timeZone: TZ }, attendees: attendees
      }, CAL_ID, evId, { sendUpdates: 'all' });
      sigs[c.id] = sig; out.updated++;
    }
  });
  props.setProperty('CAL_SIGS', JSON.stringify(sigs));
  props.setProperty('CAL_PENDING', JSON.stringify(pending));
  try { out.series = syncSchedules_(); } catch (e) { if (/sheet_schedule_pull|does not exist|Could not find/i.test(String(e.message))) out.series = 0; else throw e; }
  return out;
}

/* ------------------------------------------------ course schedules (repeating events) */

var BYDAY_ = { 1: 'MO', 2: 'TU', 3: 'WE', 4: 'TH', 5: 'FR', 6: 'SA', 7: 'SU' };

function isoDow_(ymd) { var d = new Date(ymd + 'T00:00:00Z'); var n = d.getUTCDay(); return n === 0 ? 7 : n; }
function addDaysYmd_(ymd, n) { var d = new Date(ymd + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return d.toISOString().slice(0, 10); }

/** Build the repeating-event recurrence rules from the dates the course was first locked to. */
function seriesRules_(sch) {
  var dates = (sch.orig_dates || []).map(function (d) { return String(d).slice(0, 10); }).sort();
  if (!dates.length) return null;
  var first = dates[0], last = dates[dates.length - 1], have = {};
  dates.forEach(function (d) { have[d] = 1; });
  var days = {}; (sch.weekdays || []).forEach(function (w) { days[w] = 1; });
  var pattern = 0, ex = [], cur = first, guard = 0;
  while (cur <= last && guard++ < 2000) {
    if (days[isoDow_(cur)]) { pattern++; if (!have[cur]) ex.push(cur); }
    cur = addDaysYmd_(cur, 1);
  }
  var tm = parseClassTime_(sch.class_time);
  var p = function (n) { return ('0' + n).slice(-2); };
  var rules = ['RRULE:FREQ=WEEKLY;COUNT=' + pattern + ';BYDAY=' + (sch.weekdays || []).slice().sort().map(function (w) { return BYDAY_[w]; }).join(',')];
  if (ex.length && tm) rules.push('EXDATE;TZID=' + TZ + ':' + ex.map(function (d) { return d.replace(/-/g, '') + 'T' + p(tm.h) + p(tm.m) + '00'; }).join(','));
  return { first: first, rules: rules };
}

function syncSchedules_() {
  var props = PropertiesService.getScriptProperties();
  var sigs = JSON.parse(props.getProperty('SCH_SIGS') || '{}');
  var list = rpc_('sheet_schedule_pull', {});
  var n = 0;
  list.forEach(function (sch) {
    var evId = sch.calendar_event_id || '';
    var emails = cleanEmails_(sch.emails);
    var attendees = emails.map(function (m) { return { email: m }; });

    if (sch.status === 'cancelled') {
      if (evId) {
        try { Calendar.Events.remove(CAL_ID, evId, { sendUpdates: 'all' }); } catch (e) { /* already gone */ }
        rpc_('sheet_schedule_save', { p_id: sch.id, p_event: '', p_meet: '' });
        delete sigs['S' + sch.id]; n++;
      }
      return;
    }
    var rr = seriesRules_(sch);
    var when = rr && classWhen_({ class_date: rr.first, class_time: sch.class_time, duration_min: sch.duration_min });
    if (!rr || !when) return;                                // time not understood yet
    var title = sch.title || 'Next Move India course';
    var desc = 'Next Move India course. Join from the LMS: https://nextmoveindia.org/lms/';
    var ssig = JSON.stringify([title, when.start, when.end, rr.rules, emails]);

    if (!evId) {
      var ev = Calendar.Events.insert({
        summary: title, description: desc, attendees: attendees, recurrence: rr.rules,
        conferenceData: { createRequest: { requestId: Utilities.getUuid(), conferenceSolutionKey: { type: 'hangoutsMeet' } } },
        start: { dateTime: when.start, timeZone: TZ }, end: { dateTime: when.end, timeZone: TZ }
      }, CAL_ID, { conferenceDataVersion: 1, sendUpdates: 'all' });
      rpc_('sheet_schedule_save', { p_id: sch.id, p_event: ev.id, p_meet: meetLink_(ev) });
      sigs['S' + sch.id] = ssig;
      (sch.classes || []).forEach(function (c) { sigs['C' + c.id] = classSig_(c); });
      n++; return;
    }
    if (sigs['S' + sch.id] === undefined) { sigs['S' + sch.id] = ssig; }
    else if (sigs['S' + sch.id] !== ssig) {                  // time / teacher / parents / session count changed for the whole course
      Calendar.Events.patch({
        summary: title, attendees: attendees, recurrence: rr.rules,
        start: { dateTime: when.start, timeZone: TZ }, end: { dateTime: when.end, timeZone: TZ }
      }, CAL_ID, evId, { sendUpdates: 'all' });
      sigs['S' + sch.id] = ssig;
      (sch.classes || []).forEach(function (c) { sigs['C' + c.id] = classSig_(c); });   // the new pattern is the baseline
      n++;
    }
    if (!sch.meet_link) {
      try { var got = Calendar.Events.get(CAL_ID, evId); var l = meetLink_(got); if (l) rpc_('sheet_schedule_save', { p_id: sch.id, p_event: evId, p_meet: l }); } catch (e) { /* next time */ }
    }

    /* one session moved or cancelled on its own -> change just that occurrence */
    var changed = (sch.classes || []).filter(function (c) {
      var k = 'C' + c.id; if (sigs[k] === undefined) { sigs[k] = classSig_(c); return false; }
      return sigs[k] !== classSig_(c);
    });
    if (changed.length) {
      var inst = [];
      try { inst = Calendar.Events.instances(CAL_ID, evId, { showDeleted: true, maxResults: 250 }).items || []; } catch (e) { inst = []; }
      inst.sort(function (a, b) { return String((a.originalStartTime || a.start).dateTime).localeCompare(String((b.originalStartTime || b.start).dateTime)); });
      changed.forEach(function (c) {
        var one = inst[(c.session_no || 0) - 1];
        if (!one) return;
        if (c.status === 'cancelled') {
          if (one.status !== 'cancelled') Calendar.Events.remove(CAL_ID, one.id, { sendUpdates: 'all' });
        } else {
          var w = classWhen_(c);
          if (w) Calendar.Events.patch({ start: { dateTime: w.start, timeZone: TZ }, end: { dateTime: w.end, timeZone: TZ }, status: 'confirmed' }, CAL_ID, one.id, { sendUpdates: 'all' });
        }
        sigs['C' + c.id] = classSig_(c); n++;
      });
    }
  });
  props.setProperty('SCH_SIGS', JSON.stringify(sigs));
  return n;
}

function classSig_(c) { return JSON.stringify([String(c.class_date || '').slice(0, 10), c.class_time || '', Number(c.duration_min) || 0, c.status]); }


function saveClass_(id, fields) {
  var row = { id: id };
  Object.keys(fields).forEach(function (k) { row[k] = fields[k]; });
  rpc_('sheet_table_push', { p_table: 'classes', p_rows: [row] });
}

function meetLink_(ev) {
  if (!ev) return '';
  if (ev.hangoutLink) return ev.hangoutLink;
  var pts = ev.conferenceData && ev.conferenceData.entryPoints || [];
  for (var i = 0; i < pts.length; i++) if (pts[i].entryPointType === 'video' && pts[i].uri) return pts[i].uri;
  return '';
}

function cleanEmails_(list) {
  var seen = {}, out = [];
  (list || []).forEach(function (m) {
    m = String(m || '').trim().toLowerCase();
    if (/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(m) && !seen[m]) { seen[m] = 1; out.push(m); }
  });
  return out.sort();
}

/** "5:00 PM", "5pm", "17:30", "5.30 pm" -> {h, m} or null */
function parseClassTime_(t) {
  var m = String(t || '').trim().toLowerCase().replace(/\./g, ':').match(/^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$/);
  if (!m) return null;
  var h = Number(m[1]), min = Number(m[2] || 0);
  if (m[3] === 'pm' && h < 12) h += 12;
  if (m[3] === 'am' && h === 12) h = 0;
  if (h > 23 || min > 59) return null;
  return { h: h, m: min };
}

function classWhen_(c) {
  var d = String(c.class_date || '').slice(0, 10);
  var tm = parseClassTime_(c.class_time);
  if (!/^\d{4}-\d{2}-\d{2}$/.test(d) || !tm) return null;
  var p = function (n) { return ('0' + n).slice(-2); };
  var start = d + 'T' + p(tm.h) + ':' + p(tm.m) + ':00+05:30';
  var end = Utilities.formatDate(new Date(new Date(start).getTime() + (Number(c.duration_min) || 45) * 60000), TZ, "yyyy-MM-dd'T'HH:mm:ssXXX");
  return { start: start, end: end };
}

/* ------------------------------------- other LMS tabs (generic, both ways) */

function tabCols_(def) {
  // [header, field, editable, list]; ID first, synced-version last.
  return [['ID', 'id', false]]
    .concat(def.cols)
    .concat([['Synced version (do not edit)', 'updated_at', false]]);
}

function tabRowToObject_(cols, v) {
  var o = {};
  cols.forEach(function (c, i) { o[c[1]] = cellText_(v[i]); });
  return o;
}

function tabObjectToRow_(cols, o) {
  return cols.map(function (c) {
    var val = o[c[1]];
    if (val === null || val === undefined) return '';
    if (val === true) return 'TRUE';
    if (val === false) return 'FALSE';
    return String(val);
  });
}

function ensureTab_(name, def) {
  var ss = SpreadsheetApp.getActive();
  var sheet = ss.getSheetByName(name);
  var cols = tabCols_(def);
  var header = cols.map(function (c) { return c[0]; });
  if (sheet) {
    // columns changed in a newer version of this script? rebuild the header; the data is refilled right after
    var cur = sheet.getRange(1, 1, 1, header.length).getValues()[0];
    if (cur.join('|') === header.join('|')) return sheet;
    var lastCol = Math.max(sheet.getLastColumn(), header.length);
    sheet.getRange(1, 1, 1, lastCol).clearContent();
  } else {
    sheet = ss.insertSheet(name);
  }
  sheet.getRange(1, 1, 1, cols.length).setValues([header])
    .setFontWeight('bold').setBackground('#ffedd5');
  sheet.getRange(2, 1, 1000, cols.length).setNumberFormat('@');
  sheet.setFrozenRows(1);
  cols.forEach(function (c, i) {
    if (c[3]) sheet.getRange(2, i + 1, 1000, 1).setDataValidation(
      SpreadsheetApp.newDataValidation().requireValueInList(c[3], true).setAllowInvalid(true).build());
    if (!c[2]) sheet.getRange(2, i + 1, 1000, 1).protect().setWarningOnly(true).setDescription('Managed by the LMS');
  });
  sheet.hideColumns(1);
  sheet.hideColumns(cols.length);
  return sheet;
}

function mirrorTab_(name) {
  var def = TABS[name], cols = tabCols_(def);
  var sheet = ensureTab_(name, def);
  var list = rpc_('sheet_table_pull', { p_table: def.table });
  var out = list.map(function (o) { return tabObjectToRow_(cols, o); });
  if (out.length) sheet.getRange(2, 1, out.length, cols.length).setValues(out);
  var last = sheet.getLastRow();
  if (last > out.length + 1) sheet.getRange(out.length + 2, 1, last - out.length - 1, cols.length).clearContent();
}

function refreshTabRows_(name, sheet, startRow, count) {
  var def = TABS[name], cols = tabCols_(def);
  var list = rpc_('sheet_table_pull', { p_table: def.table });
  var byId = {};
  list.forEach(function (o) { byId[o.id] = o; });
  var range = sheet.getRange(startRow, 1, count, cols.length);
  range.setValues(range.getValues().map(function (row) {
    return row[0] && byId[row[0]] ? tabObjectToRow_(cols, byId[row[0]]) : row;
  }));
}

function onTabEdit_(e, sheet, def) {
  var name = sheet.getName(), cols = tabCols_(def);
  var firstRow = e.range.getRow(), numRows = e.range.getNumRows();
  var firstCol = e.range.getColumn(), numCols = e.range.getNumColumns();
  if (firstRow + numRows - 1 < 2) return;
  var edited = [];
  for (var c = firstCol; c < firstCol + numCols; c++) {
    var d = cols[c - 1];
    if (d && d[2]) edited.push(d[1]);
  }
  var lock = LockService.getScriptLock();
  if (!lock.tryLock(25000)) { toast_('The LMS is busy, please edit again in a moment.'); return; }
  try {
    var startRow = Math.max(2, firstRow);
    var count = firstRow + numRows - startRow;
    var values = sheet.getRange(startRow, 1, count, cols.length).getValues();
    var rows = [], inserted = false;
    values.forEach(function (v) {
      var obj = tabRowToObject_(cols, v);
      if (!obj.id) {
        if (!def.insert) return;
        var any = false, row = {};
        cols.forEach(function (c) { if (c[2] && obj[c[1]] !== '') { row[c[1]] = obj[c[1]]; any = true; } });
        if (!any) return;
        inserted = true; rows.push(row); return;
      }
      if (!edited.length) return;
      var out = { id: obj.id, base_updated_at: obj.updated_at };
      edited.forEach(function (f) { out[f] = obj[f]; });
      rows.push(out);
    });
    if (!rows.length) return;
    PropertiesService.getScriptProperties().setProperty('LAST_EDIT_MS', String(Date.now()));
    var res = rpc_('sheet_table_push', { p_table: def.table, p_rows: rows });
    if (inserted) mirrorTab_(name); else refreshTabRows_(name, sheet, startRow, count);
    var n = function (x) { return Object.prototype.toString.call(x) === '[object Array]' ? x.length : Number(x || 0); };
    var msg = (n(res.updated) + n(res.inserted)) + ' saved to the LMS';
    if (n(res.conflicts)) msg += ' · ' + n(res.conflicts) + ' changed in the LMS meanwhile (sheet refreshed with the LMS version)';
    if (n(res.rejected)) msg += ' · ' + n(res.rejected) + ' not accepted: ' + (res.rejected[0] && res.rejected[0].why || 'check the values');
    toast_(msg);
  } catch (err) {
    toast_('Could not save to the LMS: ' + err.message);
  } finally {
    lock.releaseLock();
  }
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
