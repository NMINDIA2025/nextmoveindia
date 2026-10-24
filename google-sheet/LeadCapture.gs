/**
 * NEXT MOVE INDIA
 * Lead Capture System
 *
 * Handles:
 * 1. Demo Class Leads -> Sheet1
 * 2. Counseling Leads -> CounselingLeads
 *
 * IMPORTANT:
 * Keep the existing Web App deployment URL.
 */

function doPost(e) {
  try {

    // Safety check
    if (!e || !e.parameter) {
      throw new Error("No form data received.");
    }

    const ss = SpreadsheetApp.getActiveSpreadsheet();
    const data = e.parameter;

    // Identify form
    const formType = data.formType || "demo";

    // =========================================================
    // DEMO LEADS
    // =========================================================

    if (formType === "demo") {

      const sheet = ss.getSheetByName("Sheet1");

      if (!sheet) {
        throw new Error('Sheet "Sheet1" was not found.');
      }

      // Add new lead to the existing live sheet
      sheet.appendRow([
        new Date(),                         // Timestamp
        data.parentName || "",              // Parent Name
        data.phoneNumber || "",             // Phone
        data.childName || "",               // Child Name
        data.childAge || "",                // Child Age
        data.cityName || "",                // City
        "New",                              // Status
        "",                                 // Assigned Teacher
        ""                                  // Demo Date
      ]);

      // Email notification
      try {
        MailApp.sendEmail({
          to: "hello@nextmoveindia.org",
          subject: "New Demo Lead: " +
                   (data.parentName || "New Parent") +
                   " (" +
                   (data.cityName || "City not provided") +
                   ")",

          body:
            "New Demo Lead - Next Move India\n\n" +
            "Parent: " + (data.parentName || "") + "\n" +
            "Phone: " + (data.phoneNumber || "") + "\n" +
            "Child: " + (data.childName || "") + "\n" +
            "Age: " + (data.childAge || "") + "\n" +
            "City: " + (data.cityName || "") + "\n\n" +
            "Status: New"
        });
      } catch (emailError) {
        // Email failure should NOT stop the lead from being saved.
        console.log("Email notification failed: " + emailError);
      }

      return ContentService
        .createTextOutput(
          JSON.stringify({
            result: "success",
            type: "demo"
          })
        )
        .setMimeType(ContentService.MimeType.JSON);
    }


    // =========================================================
    // COUNSELING LEADS
    // =========================================================

    if (formType === "counseling") {

      let sheet = ss.getSheetByName("CounselingLeads");

      // Create tab if it doesn't exist
      if (!sheet) {

        sheet = ss.insertSheet("CounselingLeads");

        sheet.appendRow([
          "Timestamp",
          "Parent's Name",
          "WhatsApp Number",
          "Child's Name",
          "Child's Age"
        ]);

        sheet.setFrozenRows(1);
      }

      sheet.appendRow([
        new Date(),
        data.parentName || "",
        data.phoneNumber || "",
        data.childName || "",
        data.childAge || ""
      ]);

      return ContentService
        .createTextOutput(
          JSON.stringify({
            result: "success",
            type: "counseling"
          })
        )
        .setMimeType(ContentService.MimeType.JSON);
    }


    // =========================================================
    // UNKNOWN FORM TYPE
    // =========================================================

    throw new Error(
      "Unknown formType received: " + formType
    );

  } catch (error) {

    console.error("Lead capture error:", error);

    return ContentService
      .createTextOutput(
        JSON.stringify({
          result: "error",
          error: error.toString()
        })
      )
      .setMimeType(ContentService.MimeType.JSON);
  }
}
