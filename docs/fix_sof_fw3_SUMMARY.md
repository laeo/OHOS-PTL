# fix_sof_fw3 — SOF / sound card fix for `pc_ptl`

**Status:** root cause found, fix implemented, idempotency + QEMU structural
validation done. **The final "does the card appear on the real device" test can
only be done on the target machine** (QEMU has no Intel HDA DSP).

---

## 1. The symptom

On the delivered `pc_ptl` image (BUILD_ID `20261020-095517-71eee5e80258`,
kernel built `Tue Oct 20 13:28:09 CST 2026`) there is **no sound card**:

```
--- /proc/asound/cards ---
--- no soundcards ---

--- /proc/asound/devices ---
 33:        : timer
```

`audio_server` / `audio_host` are running, but nothing is registered with ALSA.

---

## 2. What the previous round assumed, and why it was wrong

The previous round (`fix_sof_fw2`) concluded:

> "The SOF PCI driver is *built in* (`CONFIG_SND_SOC_SOF_INTEL_PTL=y`) and
> probes during the initcall phase, i.e. before /system is mounted → the only
> place the firmware can come from at that moment is the initrd."

**That conclusion is refuted by the delivered image itself:**

* The firmware **is** in the initrd — verified, `lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri`
  and `sof-ptl-openmodules.ri` plus 189 topologies are in the ESP ramdisk
  (`fix_sof_fw3/work/esp_ramdisk_list.txt`, 196 `sof-ipc4` entries).
* The firmware **is** in p2 as well — `/system/lib/firmware/intel/sof-ipc4/ptl/sof-ptl.ri`
  (586 648 B), `sof-ptl-openmodules.ri` (732 388 B),
  `intel/sof-ipc4-tplg/` (189 `.tplg`), all matching the sources byte for byte.
* The Oct-16 **working** image loaded the firmware from **sda2** (the system
  partition), not from the initrd:
  `avc: denied { search } … name="sof-ipc4" dev="sda2" ino=5509`.

So the firmware was never the problem. The kernel text of the Oct-20 ESP
kernel and the Oct-17 backup kernel is byte-identical
(`.text` sha `e8bed622…`; only 9 bytes differ in `.rodata`/`.data`), and the
working image used a *different* kernel (Oct-12 16:31) — yet the failure mode
is identical to the Oct-8 image, which is a completely different code base
state. **The kernel is not the variable.**

---

## 3. The real root cause

Compare the two boot logs of the *same* driver:

### Working image (2026-10-16, `diagwork/E_dmesg.txt`)

```
[   11.291029] sof-audio-pci-intel-ptl 0000:00:1f.3: Digital mics found on Skylake+ platform, using SOF driver
[   11.291113] sof-audio-pci-intel-ptl 0000:00:1f.3: DSP detected with PCI class/subclass/prog-if 0x040100
[   22.518344] pci 0000:00:1f.3: deferred probe pending: sof-audio-pci-intel-ptl: init of i915 and HDMI codec failed
...
[  193.623296] sof-audio-pci-intel-ptl 0000:00:1f.3: bound 0000:00:02.0 (ops intel_audio_component_bind_ops [xe])
[  193.630843] sof-audio-pci-intel-ptl 0000:00:1f.3: use msi interrupt mode
[  193.640878] sof-audio-pci-intel-ptl 0000:00:1f.3: hda codecs found, mask 5
[  193.640884] sof-audio-pci-intel-ptl 0000:00:1f.3: using HDA machine driver skl_hda_dsp_generic now
[  193.650316] sof-audio-pci-intel-ptl 0000:00:1f.3:  Firmware file:     intel/sof-ipc4/ptl/sof-ptl.ri
[  193.651015] sof-audio-pci-intel-ptl 0000:00:1f.3: Loaded firmware library: ADSPFW, version: 2.14.1.1
[  194.008727] snd_hda_codec_alc269 ehdaudio0D0: autoconfig for ALC256: …
```

The probe **was deferred** (line 22.5 s) and **re-run at 193.6 s**, i.e. right
after `zz_drmmod.sh` had `insmod`'ed `xe.ko` (193.6 s). On that second pass
the i915/xe audio component could bind (`bound 0000:00:02.0 (ops
intel_audio_component_bind_ops [xe])`), the HDA codec was then found
(`hda codecs found, mask 5`), a machine driver was selected
(`using HDA machine driver skl_hda_dsp_generic now`) and only **then** was the
firmware loaded and the card registered.

### Broken image (2026-10-08, `fix_tp_ime/real_device/dmesg.1325.log`)

```
[    1.263913] sof-audio-pci-intel-ptl 0000:00:1f.3: Digital mics found on Skylake+ platform, using SOF driver
[    1.264082] sof-audio-pci-intel-ptl 0000:00:1f.3: DSP detected with PCI class/subclass/prog-if 0x040100
[    1.266389] sof-audio-pci-intel-ptl 0000:00:1f.3: use msi interrupt mode
[    1.270682] sof-audio-pci-intel-ptl 0000:00:1f.3: warning: No matching ASoC machine driver found
[    1.270684] sof-audio-pci-intel-ptl 0000:00:1f.3: error: no matching ASoC machine driver found - aborting probe
[    1.807553] sof-audio-pci-intel-ptl 0000:00:1f.3: failed to get machine info -19
```

### The difference

The broken image probes at **t = 1.26 s** — long before the graphics stack
exists — and the probe **fails hard**. The working image probes at
**t = 11.29 s**, **defers**, and is re-probed at **t = 193.6 s** once `xe.ko`
is loaded.

Why does the probe fail at 1.26 s? Look at the code path:

`sound/soc/sof/intel/hda.c:1497 hda_machine_select()`
→ `hda_generic_machine_select()` (`hda.c:1029`)
→ it only selects a machine driver if `bus->codec_mask != 0`
  (`hda.c:1041` — *"no hda codecs found!"* / *"hda codecs found, mask %lx"*)
→ `bus->codec_mask` is read from the HDA controller's `STATESTS` register by
  `hda_codec_detect_mask()` (`hda-codec.c:257`).

At t = 1.26 s the HDA controller has not been reset/enumerated yet, so
`codec_mask == 0`, no machine driver can be selected, `hda_machine_select()`
returns `NULL` and the probe **aborts with -ENODEV (-19)**:

```
sound/soc/sof/core.c:384   "failed to get machine info -19"
sound/soc/sof/intel/hda.c:241  "error: no matching ASoC machine driver found - aborting probe"
```

**A hard -ENODEV is not retried.** The device is left unbound and the kernel
never comes back to it — unless something else triggers a re-probe.

The deferred-probe machinery *would* have retried it, but only if the probe had
returned **-EPROBE_DEFER** instead of -ENODEV. In the working image the probe
*did* defer, at exactly the right place:

```
hda.c:526  ret = hda_codec_i915_init(sdev);
hda.c:527  if (ret < 0 && ret != -ENODEV) {
hda.c:528          dev_err_probe(sdev->dev, ret, "init of i915 and HDMI codec failed\n");
```

`hda_codec_i915_init()` (`hda-codec.c:415`) → `snd_hdac_i915_init()`
(`sound/hda/core/i915.c:184`) returns **-EPROBE_DEFER** when the DRM audio
component exists but is not bound yet (`i915.c:204`, *"couldn't bind with audio
component"*) — that is the "deferred probe pending" line in the working log.
When `xe.ko` is loaded later, `driver_deferred_probe_trigger()`
(`drivers/base/dd.c:176`) re-runs the probe, and this time the component
binds and the codec is found.

On the broken image the *first* probe attempt happens so early that the
`i915_gfx_present()` check (`i915.c:128`) cannot even see a display device
bound to the right parent yet, `snd_hdac_i915_init()` returns plain
**-ENODEV**, and `hda.c:527` explicitly *tolerates* -ENODEV (`ret != -ENODEV`),
so the probe continues **without deferring**, straight into the machine
selection that cannot succeed yet → hard failure.

**Root cause in one sentence:** the SOF driver is built in and probes the HDA
DSP during the initcall phase, long before the HDA controller and the `xe`
graphics driver are ready; at that point it cannot select an ASoC machine
driver and aborts hard with -ENODEV instead of deferring, and because a hard
failure is never retried by the kernel, no sound card is ever created.

### 3.1 The two possible end states of the failed probe

After the hard failure the SOF PCI device can end up in one of three states,
and the fix has to cope with all of them:

| state | how to recognise it | what the fix does |
|---|---|---|
| (a) unbound | `/sys/bus/pci/devices/…/driver` does not exist | `bind` (or `drivers_probe`) re-attaches it |
| (b) bound, probe gave up | `driver` exists, no card | unbind + bind |
| (c) bound, probe stuck | `driver` exists **and** the `AudioDSP` IRQ is still in `/proc/interrupts` | unbind (cancels the probe work queue) + bind |

State (c) is plausible because `CONFIG_SND_SOC_SOF_PROBE_WORK_QUEUE=y`
(current `.config` line 8373): `snd_sof_device_probe()` then returns 0 and
the real work happens in a work queue, so a failure inside it does not unwind
the PCI device. The `irq/209-AudioDSP` thread **is** present in the current
image's `ps` (`diagwork/d2/C_audio.txt`, "329 ? 00:00:00 irq/209-AudioDSP"),
i.e. `request_threaded_irq()` at `intel/hda.c:879` succeeded — so the current
image reached at least that point. The script therefore unbinds first
(under a timeout, because the unbind cancels the probe work queue and can
block) and then re-binds.

---

## 4. The fix

`fix_sof_fw3/stage/zz_sof_reprobe.sh` + `zz_sof_reprobe.cfg` are injected into
p2 by `fix_sof_fw3/inject.sh`. They add a boot service that **reproduces the
retry that the working image got for free from the deferred-probe machinery**:

1. wait for `/system` to be mounted (so the firmware is reachable),
2. wait for the `xe` module to be loaded (so the i915/xe audio component can
   bind — this is the condition that was missing at t = 1.26 s),
3. let the HDA controller settle,
4. if there is still no `sofhdadsp` card, **re-probe the SOF PCI device**:
   * `unbind` + `bind` on `/sys/bus/pci/drivers/sof-audio-pci-intel-ptl/`
     (the driver is `sound/soc/sof/intel/pci-ptl.c:100`), which re-runs
     `hda_dsp_probe()` from scratch including the machine-driver selection,
   * falling back to `/sys/bus/pci/drivers_probe`
     (`drivers/base/bus.c:309` → `device_attach()`),
5. log the outcome to `/dev/kmsg` with the prefix `ZZSOF:`.

The DSP is located by **PCI device id `8086:E428`** (the Intel HDA DSP) rather
than by a hard-coded BDF, because `0000:00:1f.3` is a *different* device on
other machines (on QEMU's ICH9 it is the `i801_smbus`) — the first version of
the script used the hard-coded BDF and was caught doing exactly that by the
QEMU run.

The script is best-effort and never fails the boot; it only re-probes.

---

## 5. Files

| file | purpose |
|---|---|
| `fix_sof_fw3/inject.sh` | injects the service into p2 of a partition disk; verifies firmware + service; idempotent |
| `fix_sof_fw3/stage/zz_sof_reprobe.sh` | the re-probe service |
| `fix_sof_fw3/stage/zz_sof_reprobe.cfg` | its init job (`post-init` → `start zz_sof_reprobe`, `once:1`, `secon: u:r:console:s0`) |
| `fix_sof_fw3/SUMMARY.md` | this document |
| `fix_sof_fw3/work/` | scratch: extracted p1/p2, ESP ramdisk listings, QEMU test disk |

---

## 6. How to apply

```sh
cd /home/katax/Public/OHOS/out/x86_64_virt/ohos-dbg/fix_sof_fw3
bash inject.sh <image.img>          # writes p2 of <image.img>
```

`inject.sh` only touches **p2** (the `system` partition) of the given image;
it never touches p3..p6, never the user's USB stick, and never writes outside
`fix_sof_fw3/`. It is **idempotent** — a second run leaves the image
byte-identical:

```
2089ac97b6ad7fc40d7047fe023c44e140fd4b8be090001a9ef569110b2298d4  scratch_test.img   (after run 1)
2089ac97b6ad7fc40d7047fe023c44e140fd4b8be090001a9ef569110b2298d4  scratch_test.img   (after run 2)
```

The **delivered image `partdisk/media/ohos_part_pc_ptl.img` was deliberately
not modified** in this round. To ship the fix, run `inject.sh` on it (or on a
copy) and re-`dd` it to the stick with `partdisk/dd_and_verify.sh`.

---

## 7. Validation

### 7.1 Structural (done)

* `inject.sh` run 1 → `RESULT: OK`; run 2 → `RESULT: OK` and the image sha256
  is unchanged (see above).
* Injected files land with the right ownership/mode
  (`100755` for the script, `100644` for the cfg, `root:root`) — same as the
  existing `zz_drmmod.sh`.
* The firmware is verified present in **both** places the kernel looks:
  the ESP initrd (`lib/firmware/intel/sof-ipc4/…`) and
  `/system/lib/firmware/intel/sof-ipc4/…` in p2.

### 7.2 QEMU boot (done)

`fix_secure_boot2/run_e2e.sh` with the patched disk
(`fix_sof_fw3/work/testdisk.img`, MOK-only Secure Boot, OVMF):

* the machine boots into the full OHOS userspace (5 800 `ZZPSLOG` lines),
* the new service runs and logs
  `ZZSOF: no Intel HDA DSP (8086:E428) on this machine - nothing to do`
  and exits 0 — correct, because QEMU's ICH9 has no HDA DSP,
* the boot is otherwise unaffected.

The first QEMU run (F1) used the initial version of the script and
**found two real bugs**, both since fixed:

1. it probed `0000:00:1f.3` unconditionally — on QEMU that is the
   `i801_smbus`, and the script tried to unbind it → now the DSP is located by
   PCI id `8086:E428`;
2. it waited for `/sys/class/drm/card0`, which on QEMU is `simpledrm`
   (the framebuffer), not the `xe` GPU → now it waits for `/sys/module/xe`.

### 7.3 On the real machine (still to do)

On the target device the expected result is:

```
dmesg | grep ZZSOF
  … ZZSOF: found HDA DSP at 0000:00:1f.3
  … ZZSOF: xe module is loaded
  … ZZSOF: SUCCESS: sofhdadsp card is now present
  … ZZSOF: card: 0 [sofhdadsp      ]: sof-hda-dsp - sof-hda-dsp
```

and then

```
cat /proc/asound/cards     ->  0 [sofhdadsp ]: sof-hda-dsp - sof-hda-dsp
cat /proc/asound/pcm        ->  00-00: HDA Analog …, 00-03/04/05: HDMI1/2/3, 00-06: DMIC Raw
```

dmesg should also show the *second* pass of the probe, i.e. the lines that
are missing today:

```
sof-audio-pci-intel-ptl 0000:00:1f.3: bound 0000:00:02.0 (ops intel_audio_component_bind_ops [xe])
sof-audio-pci-intel-ptl 0000:00:1f.3: hda codecs found, mask 5
sof-audio-pci-intel-ptl 0000:00:1f.3: using HDA machine driver skl_hda_dsp_generic now
sof-audio-pci-intel-ptl 0000:00:1f.3:  Firmware file:     intel/sof-ipc4/ptl/sof-ptl.ri
```

**If the card still does not appear**, the `ZZSOF: FAILED: …` lines in
`dmesg` carry the diagnosis (firmware list, whether the DSP is bound). The
next thing to look at in that case is `CONFIG_SND_SOC_SOF_HDA_AUDIO_CODEC`
(`hda_generic_machine_select()` is compiled out without it — the working
kernel has it `=y`, the current defconfig also has it `=y` at line 4085) and
whether the legacy `snd_hda_intel` driver owns `0000:00:1f.0` (it must, for
the ALC269 to be enumerated and for `codec_mask` to become non-zero).

---

## 8. Rollback

The fix is additive and confined to p2:

```sh
# remove the two files again
debugfs -w -R "rm /system/bin/zz_sof_reprobe.sh"   p2.img
debugfs -w -R "rm /system/etc/init/zz_sof_reprobe.cfg" p2.img
e2fsck -f -y p2.img
# write p2 back into the image at its GPT offset
```

Or simply use the pre-fix image
`partdisk/media/ohos_part_pc_ptl.pre_selfbuilt_grub.img.zst`
(sha256 of the delivered image: `92274c80ddd2ee19b62516d71dadf578156890937ebe11b24328035a3b2f9b44`).

---

## 9. Evidence index

| what | where |
|---|---|
| working boot log (SOF deferred → re-probed at 193.6 s → card) | `diagwork/E_dmesg.txt` lines 932-1023, 2366-2434 |
| working ALSA state | `diagwork/C_audio.txt` (`0 [sofhdadsp]`, HDA Analog + HDMI1/2/3 + DMIC) |
| broken boot log (probe at 1.26 s → hard -19) | `fix_tp_ime/real_device/dmesg.1325.log` lines 818-832 |
| broken ALSA state (current image) | `diagwork/d2/C_audio.txt` (`--- no soundcards ---`) |
| current image: AudioDSP IRQ still registered | `diagwork/d2/C_audio.txt` ("329 ? 00:00:00 irq/209-AudioDSP"); same thread exists in the working image (`diagwork/E_ps.txt:245`) |
| SOF failure path in the kernel | `sound/soc/sof/core.c:384`, `sound/soc/sof/intel/hda.c:241,1029,1041,1044,1497,1529` |
| i915/HDMI deferral | `sound/soc/sof/intel/hda.c:526-530`, `sound/soc/sof/intel/hda-codec.c:415-434`, `sound/hda/core/i915.c:128,184-206` |
| deferred-probe retry | `drivers/base/dd.c:176,301-317` |
| SOF PCI driver name | `sound/soc/sof/intel/pci-ptl.c:100` |
| firmware present in the image | `fix_sof_fw3/work/esp_ramdisk_list.txt` (196 `sof-ipc4` entries), p2 verified by `inject.sh` |
| QEMU runs | `fix_secure_boot2/runs/F1_sof_reprobe/`, `…/F2_sof_reprobe/`, `…/F3_final/`, `…/F4_final/` |

### 9.1 Note on the current image's own early boot log

The current image's `/proc/kmsg` had already rotated past the early boot by
the time the diagnostic was taken (its `E_dmesg.txt` starts at t = 1010 s), so
the exact line where *today's* image fails is not directly readable from the
captures. The Oct-8 image, which is the same failure mode, shows it
unambiguously (t = 1.26 s, hard -19). The `ZZSOF:` diagnostics the new
service prints on failure include the SOF/HDA part of the kernel log
(`dmesg | grep -iE 'sof|hda|alc269|…'`), so the next capture of the current
image will pin the exact line down.
