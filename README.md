# Get a free 4 OCPU / 24 GB ARM VM on Oracle Cloud

A walk-through that takes you from "I have nothing" to "I'm SSHed into a 4-core / 24 GB Ubuntu 22.04 ARM machine with a permanent public IP" — at zero cost, on Oracle Cloud's Always Free Tier.

**What you get:**
- 1 × Ampere A1 Flex instance (your shape): **4 OCPUs / 24 GB RAM / 50 GB boot disk** (the Always Free max — you can shrink, you can't grow past this)
- A reserved public IP (survives reboots; the VM's IP won't change)
- Ubuntu 22.04 LTS, ARM64, with Docker + Docker Compose pre-installed at first boot
- Inbound 22, 80, 443 open

**What you'll pay:** $0 indefinitely, as long as you stay within Always Free limits. Oracle requires a credit card to sign up but won't charge it unless you explicitly upgrade.

**Time to working VM:** 15–30 minutes in a region with A1 capacity. Up to several days of background retries in a locked region (Mumbai, Hyderabad, Tokyo — see "If A1 capacity is locked").

This bundle has three files, in this order of importance:

| File | Purpose |
|---|---|
| `README.md` (this file) | The guide you're reading |
| `get-arm-vm.sh` | The idempotent provisioner. Runs OCI CLI commands. Safe to re-run. |
| `cloud-init.yaml` | First-boot config the VM auto-applies (Docker, firewall, etc.) |

---

## 0. Have Claude Code do it for you (optional, easiest path)

If you have Claude Code installed (https://claude.com/product/claude-code), you can hand this whole guide off:

1. Put these three files in a folder.
2. `cd` into that folder and run `claude`.
3. Paste this prompt:

> Read `README.md` and walk me through getting an OCI A1 ARM VM. Do every step you can do automatically (install OCI CLI, generate keys, run the script, retry on capacity errors). Stop and ask me for input only when you need credentials or a console click I can't avoid (OCI signup, API key upload, region pick). After the VM is up, SSH in and confirm Docker is installed.

Claude will execute the rest of this guide for you, stopping for the parts that require your browser or your card. **Continue reading for the manual version.**

---

## 1. Sign up for Oracle Cloud Free Tier

Go to **https://www.oracle.com/cloud/free/** and sign up.

You'll need:
- A real email address (not catch-all / disposable — Oracle verifies)
- A credit / debit card (for identity verification — Oracle won't charge it without your explicit consent)
- A phone number (SMS verification)
- About 10 minutes

During signup you pick a **home region**. This is permanent — you can subscribe to other regions later but the home region cannot be changed. Pick carefully:

| Region | A1 capacity status (as of 2026-06) | Latency from India | Notes |
|---|---|---|---|
| `ap-mumbai-1` | Often locked | Lowest | Free tier in India is heavily used; expect to cron-retry for days |
| `ap-hyderabad-1` | Often locked | Lowest | Same constraint as Mumbai |
| `ap-singapore-1` | Usually available | ~80 ms | Decent if Mumbai/Hyderabad are locked |
| `ap-tokyo-1` | Often locked | ~120 ms | |
| `ap-sydney-1` | Usually available | ~150 ms | |
| `us-ashburn-1` | Almost always available | ~250 ms | Use if you don't need low latency |
| `us-phoenix-1` | Almost always available | ~260 ms | |
| `eu-frankfurt-1` | Usually available | ~150 ms | |

**Pragmatic recommendation:**
- If your workload talks to Indian users and you need low latency → pick Mumbai or Hyderabad and be patient (this guide's cron loop is for exactly this).
- If you just want an experimentation VM → pick `us-ashburn-1` or `us-phoenix-1`. You'll usually get an instance on the first attempt.

After signup completes, you'll land in the **OCI Console** (a web app at https://cloud.oracle.com).

---

## 2. Install the OCI CLI on your laptop

On macOS / Linux:

```bash
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
```

The installer asks 4–5 questions. Defaults are fine for all of them. It'll add `oci` to your PATH.

Verify:

```bash
oci --version
# expect: 3.x.y
```

On Windows: use WSL2 (`wsl --install` from PowerShell, then follow the Linux instructions inside).

Full reference: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm

---

## 3. Configure CLI authentication

Run:

```bash
oci setup config
```

This is an interactive wizard with 7 prompts. You'll need three pieces of info from the OCI Console:

| Prompt | Where to find it |
|---|---|
| Location for your config | Press Enter to accept `~/.oci/config` |
| User OCID | OCI Console → top-right profile menu → **My profile** → **OCID** → click "Copy". Starts with `ocid1.user.oc1...`. |
| Tenancy OCID | OCI Console → top-right profile menu → **Tenancy: \<name\>** → **OCID** → click "Copy". Starts with `ocid1.tenancy.oc1...`. |
| Region | Type your region's identifier (e.g. `ap-mumbai-1`, `us-ashburn-1`). The wizard offers a menu. |
| Generate new API signing keypair | Type `Y`. (Press Enter to accept the default key file paths.) |
| Passphrase for the private key | Leave empty (just press Enter) for an unattended setup — needed if you want the script to run under cron later. |

When the wizard finishes it prints **the path to your new public key**, something like:

```
~/.oci/oci_api_key_public.pem
```

You now need to upload this public key to your OCI user. The wizard reminds you. Quick path:

```bash
cat ~/.oci/oci_api_key_public.pem
# Copy the entire output including BEGIN/END lines.
```

In OCI Console:

1. Top-right profile → **My profile**
2. Resources sidebar → **API keys**
3. **Add API key** → choose **Paste public key** → paste → **Add**

Verify CLI auth works:

```bash
oci iam region list --query 'data[0]'
# Should print a region row as JSON. If you get an auth error, the key wasn't
# uploaded correctly or you typed an OCID wrong.
```

---

## 4. Run the script

In a terminal where `oci` is on PATH and `oci setup config` has been run:

```bash
cd <folder where these files are>
chmod +x get-arm-vm.sh
./get-arm-vm.sh
```

The script narrates each step (`[step]` lines) and confirms what it did (`  ok` lines). On a region with A1 capacity, it finishes in 3–5 minutes and prints:

```
============================================================
  Done. Your VM is up.
============================================================
  Region:   ap-mumbai-1
  Name:     arm-vm
  Public IP: 80.225.216.108
  SSH key:  /Users/you/.ssh/oci-arm

  Wait ~60–90 s for cloud-init (Docker install) to finish, then:

    ssh -i /Users/you/.ssh/oci-arm ubuntu@80.225.216.108
============================================================
```

**Override the defaults** if you want — every config option is at the top of the script (`VM_NAME`, `OCPUS`, `MEMORY_GB`, `BOOT_VOL_GB`, `SSH_KEY`, etc.). Set them as env vars before running:

```bash
VM_NAME=my-server OCPUS=2 MEMORY_GB=12 BOOT_VOL_GB=100 ./get-arm-vm.sh
```

---

## 5. If A1 capacity is locked (Mumbai, Hyderabad, Tokyo, etc.)

If the script exits with `exhausted retries — capacity still locked`, the script itself worked — Oracle just doesn't have A1 capacity to give you right now. The fix is patience + automation.

Wrap the script in cron and let your laptop (or a tiny throwaway VM elsewhere) keep firing it every 15 minutes until one attempt finally lands:

```bash
# 1. Make a wrapper that loads your shell env (so `oci` is on PATH inside cron).
cat > ~/oci-vm-retry.sh <<EOF
#!/usr/bin/env bash
export PATH="\$HOME/bin:\$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
cd $(pwd)
./get-arm-vm.sh
EOF
chmod +x ~/oci-vm-retry.sh

# 2. Test the wrapper once manually.
~/oci-vm-retry.sh

# 3. Add to cron — every 15 minutes.
( crontab -l 2>/dev/null; \
  echo "*/15 * * * * $HOME/oci-vm-retry.sh >> $HOME/oci-vm.log 2>&1" \
) | crontab -

# 4. Tail the log and wait. Watch for "launched: ocid1.instance..."
tail -f ~/oci-vm.log
```

Once you see the instance land:

```bash
# Remove the cron — instance is up; running again is just no-ops, but no point.
crontab -l | grep -v oci-vm-retry.sh | crontab -
```

**Tips:**
- Each cron firing's in-script retry loop is 20 attempts × 90s = 30 minutes. Don't set the cron more frequent than once per 30 minutes or attempts overlap and you may trip OCI rate limits.
- Each retry costs nothing (failed launches don't bill). You can leave this running for days.
- If your laptop sleeps, cron stops. Either keep the lid open / use `caffeinate -i ./get-arm-vm.sh` for a foreground tight loop, or run the cron from a $5/mo VPS you'll throw away once the OCI instance lands.

---

## 6. First-time access to your new VM

```bash
ssh -i ~/.ssh/oci-arm ubuntu@<your-public-ip>
```

On first SSH the host key is unknown — type `yes` to accept it.

Cloud-init takes ~60–90 seconds after the instance reaches RUNNING to finish installing Docker. Check:

```bash
ls -l /var/log/cloud-init-done   # exists when first-boot setup is fully done
docker --version                 # installed by cloud-init
docker ps                        # works for `ubuntu` without sudo
sudo tail -40 /var/log/cloud-init-output.log  # full first-boot log if anything looks off
```

If `docker` says `command not found`, cloud-init is still running. Wait another minute and try again.

---

## 7. What you can do next (optional)

You have a 4-core ARM Linux box with Docker. Some things you might want:

| Goal | Quick path |
|---|---|
| Just run containers | You're done. `docker run ...` works. |
| Run a web service publicly | Already have 80/443 open at the network layer. Bind your container to those ports. |
| Get HTTPS automatically | Install Caddy (`docker run caddy:2-alpine ...`). Point a domain's A record to your reserved IP; Caddy gets a Let's Encrypt cert on first request. |
| Connect a domain | At your DNS provider, add `A <your-domain> → <your reserved IP>`. Reserved means it survives reboots. |
| Run a database | `docker run postgres:17-alpine ...`. The 50 GB boot disk holds plenty. |
| Run k3s | `curl -sfL https://get.k3s.io \| sh -` — runs fine on a single A1.Flex node. |

---

## 8. Tearing it down

When you don't want the VM anymore — to reset your Always Free quota or to start over with different config:

**Via the console (safest):**

1. **Compute → Instances** → click your instance → **More actions → Terminate**.
2. The terminate dialog has a checkbox **"Permanently delete the attached boot volume"** — tick it (otherwise the 50 GB disk keeps counting toward your boot-volume quota).
3. **Networking → Reserved Public IPs** → your reserved IP → **Terminate** if you don't plan to launch a new VM with it.
4. **Networking → Virtual Cloud Networks** → your VCN → **Delete** (the console will warn you if anything's still attached).

**Via the CLI:**

```bash
# Identify the instance, then terminate (--preserve-boot-volume false deletes the disk).
INSTANCE_ID=$(oci compute instance list --compartment-id $(oci iam compartment list --query 'data[0]."compartment-id"' --raw-output) \
  --display-name arm-vm --query 'data[0].id' --raw-output)
oci compute instance terminate --instance-id "$INSTANCE_ID" --preserve-boot-volume false --force

# The reserved IP and VCN persist until you delete them too — see console steps above.
```

---

## 9. Troubleshooting cheat-sheet

| Symptom | Likely cause | Fix |
|---|---|---|
| `oci CLI not found` | Step 2 didn't add `oci` to PATH | `source ~/.bashrc` (or `~/.zshrc`); re-open terminal |
| `OCI CLI not authenticated` | Step 3 incomplete | Re-run `oci setup config`. Verify with `oci iam region list`. |
| `NotAuthorizedOrNotFound` on first CLI call | API public key wasn't uploaded to your user in OCI Console | See step 3, last sub-step |
| `Out of host capacity` | A1 supply locked in your region | Use the cron loop in step 5 |
| `LimitExceeded` / `service limits were exceeded` | You already have an A1 with this quota allocated | List instances with `oci compute instance list --compartment-id ...`. Adopt the existing one or terminate the duplicate. |
| SSH `Permission denied (publickey)` | Wrong key path or wrong username | Username is `ubuntu` (not `root`). Key is whatever you set `SSH_KEY` to (default `~/.ssh/oci-arm`). |
| SSH `Connection refused` | Instance still booting | Wait 60 s and try again. The reserved IP is attached the moment the script exits, but sshd takes ~30 s after RUNNING. |
| Can ping but can't SSH | Security list missing port 22 | Re-run `get-arm-vm.sh` — step 5 fixes ingress rules. |
| HTTP/HTTPS unreachable from outside | iptables inside the VM blocks them | cloud-init opens 80/443 — check `/var/log/cloud-init-done` exists. If not, cloud-init failed. Read `/var/log/cloud-init-output.log`. |

---

## Reference

- OCI Always Free Tier: https://www.oracle.com/in/cloud/free/
- OCI CLI installation: https://docs.oracle.com/iaas/Content/API/SDKDocs/cliinstall.htm
- A1.Flex shape details: https://www.oracle.com/cloud/compute/arm/
- Ampere A1 capacity availability tracker (community-maintained, useful to gauge if your region is currently locked): https://github.com/hitrov/oci-arm-host-capacity (this is an alternative to the cron approach — a service that retries from a small permanent box. Optional.)
