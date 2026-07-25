# mnemo

Syncs **Ren'Py game saves** to a folder in your Google Drive. Runs in the
background with a local web interface at `localhost:4000`.

The full design lives in [CLAUDE.md](CLAUDE.md). Current state: **v0** —
scan of the OS Ren'Py root, enrollment, manual sync button, OAuth end to
end, content-addressed blob dedup, screenshot extraction for covers.

## Running

```sh
mix setup
mix phx.server
```

Then open [`localhost:4000`](http://localhost:4000).

To try everything without a Google account (in-memory fake Drive):

```sh
MNEMO_FAKE_DRIVE=1 mix phx.server
```

## Google OAuth setup (one-time)

mnemo talks to Drive as an *installed app* with the `drive.file` scope —
it can only see files it created itself.

1. Create a project at [console.cloud.google.com](https://console.cloud.google.com)
   and enable the **Google Drive API**.
2. Configure the OAuth consent screen, add the
   `https://www.googleapis.com/auth/drive.file` scope, and **publish the
   app to production**. In "Testing" status refresh tokens expire after
   7 days, which kills a background sync tool weekly. Personal-use apps
   (fewer than 100 users) do not need to complete verification — you just
   click through the "unverified app" screen once.
3. Create an OAuth client of type **Desktop app** and paste its
   credentials into **Settings** in the mnemo interface
   ([`localhost:4000/settings`](http://localhost:4000/settings)).

Click **Connect Google Drive**; the browser opens, you authorize, done.
The refresh token is stored with `0600` permissions under your user
config directory.

Environment variables work as a fallback when nothing is saved in
Settings (useful for development):

```sh
export MNEMO_GOOGLE_CLIENT_ID="....apps.googleusercontent.com"
export MNEMO_GOOGLE_CLIENT_SECRET="..."
mix phx.server
```

## Development

```sh
mix test        # runs against the in-memory Drive fake
mix precommit   # compile --warnings-as-errors + format + tests
```

Test fixtures are synthetic `.save` zips with the exact member layout of
real Ren'Py 7.8/8.x saves (`log`, `json`, `screenshot.png`, `extra_info`,
`renpy_version`, `signatures`), including a truncated one to prove that
zip validation rejects corrupt files instead of propagating them.
