# Google Sheet <-> LMS sync (plain-language setup)

1. Supabase > SQL Editor > run `supabase/phase2_sheet_sync.sql` (the first block).
2. Run the small STEP 2 block at the bottom of that file. It shows a "sync password" - copy it.
3. Open the Google Sheet **NextMoveIndia Dashboard Data** > Extensions > Apps Script.
   Delete the sample code, paste all of `google-sheet/Code.gs`, click Save, then reload the sheet.
4. A new menu **Next Move LMS** appears. Choose **1. Connect to the LMS** and paste the sync password
   (Google asks you to authorise the script once: Advanced > Go to project > Allow).
5. Choose **3. Turn on automatic sync**.

Result: website enquiries from `Sheet1` flow into the LMS; every lead appears in the tab **LMS Leads**;
edits in the white columns (course, status, counselor email, follow-up, demo, notes) are saved to the LMS
within seconds; if the LMS changed the same lead meanwhile, the LMS version wins and you are told.
