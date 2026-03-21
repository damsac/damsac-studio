# Bootstrapping the damsac server

Run these steps in order to set up a freshly provisioned damsac server.

## 1. Authenticate GitHub CLI

```bash
gh auth login
```

Choose: GitHub.com, HTTPS, Login with a web browser. Follow the prompts.

After auth, verify:
```bash
gh auth status
```

## 2. Clone repos into shared workspace

```bash
cd /srv/damsac
gh repo clone damsac/damsac-studio
gh repo clone damsac/Murmur
```

Verify permissions are correct (should be group `damsac`):
```bash
ls -la /srv/damsac/
```

If group isn't `damsac`, fix with:
```bash
sudo chgrp -R damsac /srv/damsac/damsac-studio /srv/damsac/Murmur
sudo chmod -R g+w /srv/damsac/damsac-studio /srv/damsac/Murmur
```

## 3. Set up git identity

Git should already be configured via Home Manager (`git config user.name` and `git config user.email`). Verify:

```bash
git config --global user.name
git config --global user.email
```

Configure `core.sharedRepository` on both repos so shared files stay group-writable:

```bash
cd /srv/damsac/damsac-studio && git config core.sharedRepository group
cd /srv/damsac/Murmur && git config core.sharedRepository group
```

## 4. Authenticate Claude Code

```bash
claude
```

Follow the prompts to authenticate. This only needs to be done once per user.

## 5. Create dashboard password (if not already done)

```bash
sudo mkdir -p /run/secrets
echo "your-password-here" | sudo tee /run/secrets/damsac-dashboard-pw > /dev/null
sudo chmod 600 /run/secrets/damsac-dashboard-pw
```

## 6. Rebuild in dev mode

```bash
cd /srv/damsac/damsac-studio
nrsd
```

This switches the server to dev mode — the studio API runs via `air` with hot reload. Verify:

```bash
systemctl status damsac-studio
curl -s http://localhost:8080/v1/health
```

## 7. Verify everything works

```bash
# Service running?
systemctl status damsac-studio

# Dashboard accessible?
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/dashboard

# tmux shared socket exists?
ls -la /run/tmux-damsac/

# Claude Code works?
claude --version

# GitHub CLI works?
gh auth status
```

## Quick reference

| Command | What it does |
|---------|-------------|
| `nrs` | Rebuild prod mode |
| `nrsd` | Rebuild dev mode (hot reload) |
| `nrt` | Test rebuild without switching |
| `dw <user>` | Watch teammate's tmux (read-only) |
| `dp` | Join/create shared pair session |
| `/ship` | Claude-assisted review, commit, push, rebuild |
