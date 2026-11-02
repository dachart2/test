# Surface als reines Surf-Gerät (Edge-Kiosk)

Für Windows 11 Pro, ausgelegt auf Surface mit Snapdragon (ARM64).

## Was passiert

| Schritt | Inhalt |
|---|---|
| Debloat | Entfernt vorinstallierte Apps (News, Wetter, Xbox, Teams, Outlook, Copilot, Clipchamp, Widgets, Phone Link, …) für alle User **und** aus dem Provisioning-Image. Deaktiviert Recall (Copilot+ PC). Deinstalliert OneDrive. |
| Richtlinien | Keine Werbung/Tipps/vorgeschlagenen Apps, kein Copilot, kein Recall/Click to Do, keine Widgets, keine Websuche im Startmenü, OneDrive blockiert, Edge ohne Shopping/Sidebar/Rewards/Erststart-Assistent. Telemetrie auf „Erforderlich“ (Minimum bei Pro). |
| Kiosk | Assigned Access mit Edge. Windows legt selbst ein lokales Kiosk-Konto an (Anzeigename „Surfen“, kein Passwort, keine Adminrechte) und meldet es automatisch an. Der User sieht nur Edge im Vollbild. |

**Bewusst nicht angefasst:** Windows Update, Defender, Firewall, Treiber/Firmware, Surface-App, Microsoft Store, Edge.

## Ausführen

1. Mit dem **Admin-Konto** anmelden. Ordner `Surface-Kiosk` aufs Surface kopieren.
2. `Setup-SurfaceKiosk.cmd` doppelklicken (fragt UAC ab) – oder in einer Admin-PowerShell:
   ```powershell
   .\Setup-SurfaceKiosk.ps1 -WhatIf     # nur anzeigen, nichts ändern
   .\Setup-SurfaceKiosk.ps1             # ausführen
   ```
3. Neu starten → Surface startet direkt in den Edge-Kiosk.

Log: `C:\ProgramData\SurfaceKiosk\setup.log`

### Parameter

| Parameter | Standard | Bedeutung |
|---|---|---|
| `-StartUrl` | `https://www.google.com` | Startseite |
| `-KioskType` | `PublicBrowsing` | `PublicBrowsing` = Adressleiste + Tabs, nur InPrivate. `Fullscreen` = eine Seite ohne Adressleiste (Digital Signage). |
| `-IdleResetMinutes` | `15` | Nach X Minuten Inaktivität wird die Sitzung zurückgesetzt. `0` = nie. |
| `-KioskDisplayName` | `Surfen` | Name des Kiosk-Kontos |
| `-SkipDebloat` / `-SkipPolicies` / `-SkipKiosk` | – | Schritt überspringen |

## Wichtig zu wissen (Einschränkungen)

- **Nichts bleibt gespeichert.** Im Modus `PublicBrowsing` läuft Edge nur InPrivate: Logins, Passwörter, Verlauf, Cookies werden beim Reset/Abmelden gelöscht. Wenn z. B. Gmail/Netflix dauerhaft eingeloggt bleiben soll, ist dieser Kiosk-Modus der falsche – dann braucht es einen Multi-App-Kiosk oder einen normalen Standard-User (kann ich nachliefern).
- **Keine Downloads/Dateien, kein Drucken über andere Apps, keine Einstellungen** (WLAN wechseln geht nur vom Admin-Konto aus – WLAN vorher im Admin-Konto einrichten).
- **Zum Admin-Konto wechseln:** `Strg+Alt+Entf` (ohne Tastatur: Windows-Taste + Ein/Aus) → *Abmelden*. Damit nicht sofort wieder das Kiosk-Konto angemeldet wird, beim Erscheinen des Anmeldebildschirms **Shift gedrückt halten**, dann das Admin-Konto wählen.
- **Rückgängig machen:** `Remove-SurfaceKiosk.ps1` als Admin ausführen, neu starten. Entfernte Apps lassen sich aus dem Store neu installieren; Richtlinien liegen unter `HKLM:\SOFTWARE\Policies\Microsoft`.
- Das Admin-Konto sollte ein **sicheres Passwort** haben – es ist die einzige Hürde zwischen Kiosk und vollem Systemzugriff.
