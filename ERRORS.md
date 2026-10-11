# Curtain error codes

Errors shown in Curtain's Settings window start with a code in square brackets. Look the code up here, or paste it with the message into your LLM of choice.

| Code | Where | Meaning | What to do |
|------|-------|---------|------------|
| `CUR-LOGIN-01` | Settings status line, after switching **Open at Login** | macOS refused to add or remove Curtain as a login item (`SMAppService` error, shown after the code). | Check that Curtain is in `/Applications`, then open System Settings › General › Login Items & Extensions and switch Curtain on or off there. If it keeps failing, quit and reopen Curtain and try again. |
