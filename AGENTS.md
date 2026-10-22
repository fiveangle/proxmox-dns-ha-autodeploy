### Git usage ###
- Check the branch before making changes. If on main, develop, or another shared integration/release branch, create and switch to a dedicated task branch before editing. Do not use develop as a task branch. Branch creation is authorized by this rule; no separate permission is needed. Name branches by work type: fix/<task> for fixes, feat/<task> for features, refactor/<task> for refactoring, doc/<task> for documentation-only changes. Use a concise, lowercase, hyphen-separated task name. Reuse an existing task branch only for that same task.
- Commit headline prefixes: feat: for features, fix: for fixes, refactor: for refactoring, and doc: for documentation-only changes.
- Never add agent attribution to commits.
- Land task branches on main by rebasing them onto main and fast-forwarding (`git merge --ff-only`); never create merge commits. Squash only work-in-progress commits before landing; keep meaningful separate commits.
