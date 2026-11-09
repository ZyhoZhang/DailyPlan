# Security and privacy

Goals, reflections and deadlines are local, unencrypted files. Keep backups
private. Do not include real data/, logs/ or app logs in public issues or commits.

The web companion binds to 127.0.0.1 by default and has no authentication.
Do not expose it to a network, reverse proxy or public hosting service.
The native app has no analytics or server synchronization. Opening a note link
uses your browser and that website's normal network behavior.

## Storage boundaries

Current native and web builds coordinate through a POSIX lock on one computer.
Upgrade all active copies before using them together. Older apps, manual editors
and cloud-sync clients do not participate. Cloud folders are not supported as
multi-computer live databases. Same-field edits use the last successful write.

Invalid or unreadable JSON stops edits without replacing the state or backup.
The native app displays storage errors. Preserve unsaved drafts before
navigating away. A rolling backup holds the previous valid state; it is not
versioned backup storage. If the final state write fails after backup creation,
the backup may hold the still-current valid state. Keep separate private backups.

## Vulnerability reports

Do not post credentials, private history or a working exploit in public issues.
Use GitHub private vulnerability reporting once the maintainer enables it.
Before publication, configure and verify that private reporting route.
Until then, do not upload sensitive material.
