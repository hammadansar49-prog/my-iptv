// Instant push for MY IPTV announcements. The Android app also polls every
// ~15 min (WorkManager), so this is an accelerator, not the only path.
const { onValueWritten } = require("firebase-functions/v2/database");
const { initializeApp } = require("firebase-admin/app");
const { getMessaging } = require("firebase-admin/messaging");

initializeApp();

exports.myiptvAnnouncementPush = onValueWritten(
  {
    ref: "/iptv/announcement",
    instance: "theottdeals-reviews-default-rtdb",
    // RTDB instance region; change if the database lives elsewhere.
    region: "us-central1",
  },
  async (event) => {
    const before = event.data.before.val() || {};
    const after = event.data.after.val();
    if (!after) return; // deleted
    const text = String(after.text || "").trim();
    const createdAt = Number(after.created_at) || 0;
    // Only a NEW announcement: edits that keep created_at (or clearing text)
    // must not re-notify.
    if (!text || !createdAt || createdAt === Number(before.created_at)) return;
    const expiresAt = Number(after.expires_at) || 0;
    if (expiresAt > 0 && expiresAt < Date.now()) return;

    // Data-only on purpose: the app's native receiver draws it with the same
    // dedupe as the poll (no double notification) and skips it while the app
    // is open (the live popup shows it). FCM data values must be strings.
    await getMessaging().send({
      topic: "iptv_announcements",
      data: {
        type: "announcement",
        text,
        created_at: String(createdAt),
        expires_at: String(expiresAt),
      },
      android: { priority: "high", ttl: 24 * 60 * 60 * 1000 },
    });
  }
);
