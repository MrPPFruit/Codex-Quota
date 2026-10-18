# Live evidence: quota transport recovery

- Captured: 2026-10-18 21:08 Asia/Shanghai.
- Entry: installed `/Applications/Codex Quota.app`, launched through the normal macOS app entry while ChatGPT was already running.
- Installed executable SHA-256: `1cf589907b97f81ae102e6c8a996974c15baf53a1f958ba3ffd7b39e716f168e`.
- Process evidence: accessory PID `13431` remained running with its `codex app-server --stdio` child PID `13439`.
- CUA accessibility state: menu-bar item reported `本周额度` and a non-empty remaining percentage with status `充足`; screenshot showed the live weekly percentage icon. The observed quota value and account identity are intentionally omitted.
- No accessory or ChatGPT restart was needed between launch and the successful UI observation. The old installed accessory was closed through its own Quit menu before replacement.
- OSLog query for the new process returned no lifecycle events in this normal-success observation window. This does not prove the injected cleanup-failure branch; that branch is covered by the same-client regression below.
