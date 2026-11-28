# Invariants

| claim | node | anchor |
| --- | --- | --- |
| a bad client frame decodes to `:ignore`, never a crashed session | / | ※ bad-frame-ignored |
| a cross-origin browser upgrade is refused unless `:check_origin` admits it | / | ※ origin-refused |
| reaps stop the session directly, never through the supervisor, so a slow hangup never blocks `start/2` | / | ※ reap-unsupervised |
