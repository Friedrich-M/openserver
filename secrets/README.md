# secrets/

Three files, and nothing else:

- `secrets.sh` — locks and unlocks the blob (`srvlock`, `srvunlock`).
- `secrets.enc` — `~/.secrets.env`, `~/.git-credentials`,
  `~/.config/rclone/rclone.conf` and, with `srvlock --with-ssh`, `~/.ssh/id_*`, encrypted with a passphrase so the
  credentials can travel inside the bundle. `setup.sh` offers to unlock it on
  a new machine; `srvunlock` does it later.
- `secrets.env.example` — the template `setup.sh` seeds `~/.secrets.env` from
  when there is no blob to unlock.

Create or refresh the blob with:

```bash
srvlock          # or: secrets/secrets.sh lock
```

You will be offered a generated passphrase — take it and put it in your
password manager. The blob is git-ignored: it reaches other machines inside
the zip `install/make-bundle.sh` builds, or by `scp`, never through the repository.
A blob locked with a passphrase the check called weak is marked so in its
header, and `install/make-bundle.sh` leaves it out of the zip; carry it by `scp`
instead.

`install/make-bundle.sh` ships only these three files from here, and
refuses to build if a plaintext `secrets.env` has turned up anywhere.
