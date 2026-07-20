# GFC OEM — package/install recovery & full image build (build host)

## Why `package/compile` Error 2 after grub/gfc looked OK

Parallel `make package/compile -jN` rebuilds the **entire** package world.
One unrelated package failing aborts with Error 2; the last lines may show a
**successful** package (grub2, gfc-client). That is not the root cause.

`patchelf: cannot find section '.dynamic'` on gfc-* is normal (static Go).

## Correct recovery (kernel + kmods only)

Userspace ipks stay in `bin/packages/x86_64/`. Only refresh:

`bin/targets/x86/64/packages/` → `kernel_*.ipk` + kmods.

```bash
cd /opt/gfc/sip-proxy && git pull
chmod +x gfc-client/deploy/immortalwrt/scripts/recover-package-install.sh

# Default: NO full package/compile
bash gfc-client/deploy/immortalwrt/scripts/recover-package-install.sh

# Then build image (also skips full world compile unless you set the env)
bash gfc-client/deploy/immortalwrt/scripts/rebuild-gfc-image.sh
```

Only if required userspace ipks are missing and selective compile is not enough:

```bash
GFC_FULL_PACKAGE_COMPILE=1 bash gfc-client/deploy/immortalwrt/scripts/recover-package-install.sh
```

## Check required ipks (build host)

```bash
cd /opt/gfc/immortalwrt
HASH=$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' | head -1 | xargs cat | tr -d '[:space:]')
KVER=$(find build_dir -path '*/linux-x86_64/linux-*/.vermagic' | head -1 | xargs dirname | xargs basename | sed 's/^linux-//')
ls -la bin/targets/x86/64/packages/kernel_"${KVER}~${HASH}"*.ipk

PKGS='gfc-client luci-app-gfc luci-base luci-theme-bootstrap luci-mod-admin-full
sing-box unbound-daemon unbound-checkconf kmod-tun kmod-nft-core nftables-json
dnsmasq-full libcap-bin ca-bundle ip-full tc-tiny kmod-sched-core kmod-ifb
kmod-tcp-bbr kmod-sched autossh curl wget-ssl tcpdump iftop bmon
resize2fs parted partx-utils losetup'
for p in $PKGS; do
  find bin -name "${p}_*.ipk" | grep -q . || echo "MISSING $p"
done
```

## Find the real failing package (if you must full-compile)

```bash
cd /opt/gfc/immortalwrt
make package/compile -j1 V=s 2>&1 | tee /tmp/gfc-pkg.log
grep -nE 'Error [0-9]|make\[[0-9]+\]: \*\*\*' /tmp/gfc-pkg.log | tail -50
# or with BUILD_LOG=1:
find logs/package -name compile.txt 2>/dev/null | while read f; do
  grep -q 'Error\|failed' "$f" 2>/dev/null && echo "$f"
done
```
