Review all staged and unstaged changes in the current repository against the project standards defined in CLAUDE.md.

Steps:
1. Run `git status` and `git diff` to see all changes
2. Review every change for:
   - Code style: single flat package, stdlib net/http only, no framework
   - Templates in api/templates/, static assets in api/static/
   - HTMX for dashboard interactivity
   - SQLite safety: single connection, WAL pragmas, idempotent inserts
   - Auth uses crypto/subtle.ConstantTimeCompare (never ==)
   - No debug code, no temporary files, no hardcoded secrets
3. Run `cd api && go vet ./...` to check for issues
4. Run `cd api && go build -o /dev/null .` to verify compilation
5. If issues found, report them and stop. Do not commit broken code.
6. If everything passes, draft a commit message following the repo's conventional commit style (look at recent `git log --oneline -10` for examples)
7. Stage relevant files and commit (pause for user approval on the commit message)
8. Run `git push`
9. Ask the user if they want to rebuild prod now (`nrs`) or stay in dev mode
