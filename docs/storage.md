# Storage methodology

Tier 1 storage tests use the same logical `fio` profiles on macOS and Linux:

| Profile | Access pattern | Block size | Queue depth | Jobs |
|---|---|---:|---:|---:|
| `4k_qd1` | random read | 4 KiB | 1 | 1 |
| `seq` | sequential read | 1 MiB | 32 | 1 |
| `mixed` | random 70/30 read/write | 16 KiB | 16 | 4 |

The suite records the selected `ioengine`, scratch path, mount point, filesystem,
device, direct I/O flag, and fio job arguments in each iteration's `extra`
object. This is necessary because the test is intentionally comparable at the
profile level, not identical at the kernel I/O implementation level.

Current native engines:

| OS | fio ioengine |
|---|---|
| macOS | `posixaio` |
| Linux / WSL | `libaio` |
| Fallback | `psync` |

## Interpretation

Storage scores should be read as platform storage-stack behavior for the chosen
scratch directory. They are not a pure SSD hardware benchmark.

Important caveats:

- `--direct=1` is requested everywhere, but direct-I/O semantics differ across
  macOS and Linux.
- `posixaio` and `libaio` are not the same kernel path.
- Filesystem, encryption, mount options, and sync/cloud folders can materially
  affect results.
- The default quick-run file sizes and runtimes are tuned for fast signal, not
  publication-grade storage characterization.

For publishable comparisons, use a dedicated scratch directory on the target
disk, outside cloud-sync folders, with the same power state and thermal
preflight on every machine.
