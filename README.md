# pool-probe

Throwaway probe of Fount Cloud's shared runner pool in a real Tinfoil enclave
(fount `docs/features/fount-fleet/m4-cloud-runners.md` §5.1c). Holds no customer data.

1. Build Image (`version`), pin both digests and the harness digest in `tinfoil-config.yml`.
2. Org secret `FOUNT_BROKER_REGISTRY_TOKEN`: a classic PAT with `read:packages` only.
3. Tinfoil Release (`version`), then `tinfoil container create` from the release.
4. From a laptop: a dev `fount-coordinator --runner-addr https://<domain> --runner-repo
   unattested`, fed the runner smoke jobs.
5. Delete the container.
