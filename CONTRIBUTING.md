# Contributing

Thanks for helping. OpenServer is plain bash and POSIX sh with no build step.

1. Read [AGENTS.md](AGENTS.md): the layout, where each kind of change goes,
   and the rules every change keeps (it is written for coding agents and
   people alike). [docs/architecture.md](docs/architecture.md) explains how
   the pieces fit.
2. Make the change, with a check in `tests/check.sh` when it can be tested
   offline ([docs/testing.md](docs/testing.md#adding-a-check)).
3. Run `tests/check.sh` (on a Mac, `/bin/bash tests/check.sh`). It works on
   a scratch copy and a scratch `$HOME` and installs nothing. Do not run
   `setup.sh` itself on your own machine to test: CI does the real installs
   on throwaway Linux and macOS machines.
4. Say in the commit message what users will notice, if anything.
5. Keep personal information out: no names, accounts, hostnames or paths
   from your own machines ([docs/releasing.md](docs/releasing.md#before-every-push)).

Bug reports are most useful with the output of `setup.sh --dry-run` and
`srvinfo` from the affected machine, with anything personal removed.
