# switchboard-agent

The control half of [Switchboard](https://github.com/crockalet/switchboard). A small loopback HTTP server
that starts, stops and restarts local dev services on request.

It exists as a separate binary because the droplet cannot be the thing that runs
commands: a Droplet is native code inside Droppy's process, and DroppyKit's
capability list has no exec entry to declare. Everything that spawns a process
lives here, outside the reviewed and signed bundle.

## Install

```bash
swift build -c release
cp .build/release/switchboard-agent ~/.local/bin/
```

## Configure

`~/.config/switchboard/services.json` (override with `SWITCHBOARD_CONFIG`):

```json
{
  "port": 7878,
  "services": [
    {
      "id": "baguette",
      "name": "Baguette",
      "kind": "launchd",
      "label": "com.example.baguette-serve",
      "port": 8421,
      "url": "https://sim.localhost"
    },
    {
      "id": "docs",
      "name": "Docs site",
      "kind": "command",
      "command": "pnpm",
      "args": ["dev"],
      "workingDirectory": "/Users/you/repos/docs",
      "port": 3000
    }
  ]
}
```

`switchboard-agent config example` prints that.

### Two kinds

**`launchd`** addresses an existing agent by `label`. The command and its flags
stay in the plist, so this file never repeats them, and `launchctl` does the
work: `kickstart` to start, `kill SIGTERM` to stop, `kickstart -k` to restart.
Stopping never unloads the job, so starting it again works.

**`command`** is a command the agent spawns and supervises itself, through a
login shell so `PATH` resolves the way it does when you type it. Pids go in
`~/.local/state/switchboard/<id>.pid` and output in `<id>.log`, so an agent
restart does not orphan anything.

`port` is optional but worth setting: liveness then means "something is
listening there", which is truer than "the supervisor believes it is up" —
launchd will happily report a job as loaded while the process inside it fails to
bind.

## Use

```bash
switchboard-agent serve            # the API the droplet talks to
switchboard-agent list             # status, in the terminal
switchboard-agent restart baguette
```

To keep it running, make it a launchd agent of its own.

## API

All on `127.0.0.1` only. Every endpoint but `/v1/health` needs the
`X-Switchboard-Token` header, whose value `serve` writes to
`~/.config/switchboard/token` (mode 0600) the first time it runs. Without it the
agent answers `401`, so no other local process or web page can drive it, and the
custom header means a browser's preflight fails before a request is sent.

| | |
| --- | --- |
| `GET /v1/health` | `{"ok": true, "services": 1}` |
| `GET /v1/services` | every service, with status, pid, port, url and allowed actions |
| `POST /v1/services/<id>/start` | |
| `POST /v1/services/<id>/stop` | |
| `POST /v1/services/<id>/restart` | |
| `GET /v1/services/<id>/logs?lines=200` | the tail of the service's log, and its path |

A refused action answers `400` with `{"ok": false, "message": "..."}`.

## Licence

MIT.
