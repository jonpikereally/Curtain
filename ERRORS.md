# Curtain error codes

Errors shown in Curtain's Settings window start with a code in square brackets. Look the code up here, or paste it with the message into your LLM of choice.

| Code | Where | Meaning | What to do |
|------|-------|---------|------------|
| `CUR-LOGIN-01` | Settings status line, after switching **Open at Login** | macOS refused to add or remove Curtain as a login item (`SMAppService` error, shown after the code). | Check that Curtain is in `/Applications`, then open System Settings › General › Login Items & Extensions and switch Curtain on or off there. If it keeps failing, quit and reopen Curtain and try again. |
| `CUR-UPD-01` | Update alert | No update source is set. | Right-click the arrow › **Update Source…** and leave it empty to use the built-in GitHub feed. |
| `CUR-UPD-02` | Update alert | The update source isn't a web link (`https://…`) or a file path. | Fix or clear it under **Update Source…**. |
| `CUR-UPD-03` | Update alert | Curtain couldn't download the feed or the update zip (offline, HTTP error, file missing). | Check your connection. The repo must be public for GitHub updates to work. Try again in a few minutes, since GitHub caches for about 5. |
| `CUR-UPD-04` | Update alert | The downloaded zip isn't a usable Curtain.app (missing, wrong bundle ID, no executable, or unzip failed). | Download `updates/Curtain.zip` from the repo by hand and run `Install Curtain.command`. |
| `CUR-UPD-05` | Update alert | Anything else, usually a `latest.json` that isn't valid JSON. | Check `updates/latest.json` in the repo or your custom feed. |
