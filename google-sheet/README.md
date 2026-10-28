# Google Sheet <-> LMS sync (plain-language setup)

0. Supabase > SQL Editor > run `supabase/phase1_foundation.sql`, then `supabase/phase2_sheet_sync.sql`, then `supabase/phase3_workspace.sql` (answer "Run and enable RLS" if asked).
1. (Already done above.) Phase 2 also creates the private sync password table.
2. Run the small STEP 2 block at the bottom of that file. It shows a "sync password" - copy it.
3. Open the Google Sheet **NextMoveIndia Dashboard Data** > Extensions > Apps Script.
   Delete the sample code, paste all of `google-sheet/Code.gs`, click Save, then reload the sheet.
4. A new menu **Next Move LMS** appears. Choose **1. Connect to the LMS** and paste the sync password
   (Google asks you to authorise the script once: Advanced > Go to project > Allow).
5. Choose **3. Turn on automatic sync**.

Result: website enquiries from `Sheet1` flow into the LMS; every lead appears in the tab **LMS Leads**;
edits in the white columns (course, status, counselor email, follow-up, demo, notes) are saved to the LMS
within seconds; if the LMS changed the same lead meanwhile, the LMS version wins and you are told.

## More tabs (phase 3)
After step 5 the script also creates and keeps in step these tabs: **LMS Students, LMS Teachers, LMS Classes,
LMS Materials, LMS Tasks, LMS Payments, LMS Attendance**. Edit white columns freely. To add a new student,
teacher, class, material or task, type a new row (leave the hidden ID cell empty). New payments and
attendance rows are created in the LMS; their status/amount can be edited in the sheet.

## Course schedules (phase 11)

Run `supabase/phase11_schedules.sql`, then paste the latest `Code.gs` into the `LMS` script file and save.
In the LMS, **Course Schedules → New course schedule** locks days + time + teacher + students for a whole
course. The script then adds ONE repeating Google Calendar event with ONE Meet link (teacher and parents are
invited once), and keeps it in step when you move or cancel a single session, change the time for the remaining
sessions, add sessions, or stop the course. Run **Create Meet links + Calendar events now** to force it.
