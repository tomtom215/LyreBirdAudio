# SECURITY-GUIDE notes (for the documentation pass)

Fixed early because it affected every deployment that followed the guide
(DOC-01): literal `${VAR}` password, `^…$` path without `~`, WebRTC row, API
"localhost only" wording, and the missing local password-less user.

To revisit once the code lands:
- API/metrics bind address text changes with D9 (loopback by default).
- The "regenerates the file on every start" note changes with LB-22/D10
  (operator-owned files are never overwritten; managed marker line).
- Installer-config SRT/MoQ sentence changes with the installer fix.
- Unit name stays `mediamtx-audio.service` (D1/D12).
