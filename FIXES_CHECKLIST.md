# Noor App Fix Checklist

- [x] **1. Gemini API key security — SOLVED** — Gemini key Cloudflare Worker secret me hai; app sirf secure proxy URL use karti hai. Direct key APK/.env me nahi hai.
- [ ] **2. Exposed Gemini key rotation — USER ACTION REQUIRED** — Google AI Studio me exposed key revoke karni hai.
- [ ] **3. New-user alert default — SOLVED** — fresh profiles default to At time; onboarding existing settings overwrite nahi karta.
- [ ] **4. Per-prayer offset scheduling** — selected offset ke exact waqt alert.
- [x] **4a. Maghrib Awwal rule** — Maghrib display, Jamaat aur alert ab masjid ke sunset ke 2 minutes baad calculated honge; manual/OCR edit se replace nahi honge.
- [ ] **5. Bell terminology — SOLVED** — Home bell me Band ko Off kar diya.
- [ ] **6. Alert behavior tests** — At time, offset, Off, Mute, Azaan, force-close, reboot, timezone/city.
- [ ] **7. Existing-settings migration — SOLVED** — onboarding reopen par settings reset nahi hoti.
- [ ] **8. Photo/time verification gate — SOLVED** — save se pehle photo verification required.
- [ ] **9. OCR correction UI — SOLVED** — read-only fields same clock picker se edit hote hain.
- [ ] **10. OCR states** — OCR, corrected, missing/uncertain states.
- [ ] **11. Photo preview** — full-screen/zoom option.
- [ ] **12. Jamaat-column clarity** — Start/Azan aur Jamaat clear distinction.
- [ ] **13. 24-hour user option remove — SOLVED** — user-facing option removed; internal format allowed.
- [ ] **14. 24-hour text cleanup** — remaining user-facing wording cleanup.
- [ ] **15. Home greeting alignment — SOLVED** — greeting Hero card alignment ke kareeb.
- [ ] **16. Bell dialog simplify** — sound mode aur timing clear two-step wording.
- [ ] **17. Permission flow** — clear explanations for required permissions.
- [ ] **18. Offline behavior** — cached times/local OCR/manual flow usable.
- [ ] **19. Firebase error messages** — readable user-facing errors.
- [ ] **20. Package ID consistency** — Android/Firebase/Google Sign-In/release config.
- [ ] **21. Full analyze/test/build** — complete verification and device install.

## Notes
- `SOLVED` tabhi mark hoga jab code change ke saath verification bhi ho.
- Existing user settings bina permission reset nahi honi chahiye.
