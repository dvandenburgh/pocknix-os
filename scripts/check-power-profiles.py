#!/usr/bin/env python3
# Build-time gate for pocknix-perfd's profiles: a broken factory file or BSP drop-in must fail
# here, never on a device. Runs the daemon's own parser against each family's recorded
# frequency list.
import copy
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PKG = os.path.join(ROOT, "packages/shared/pocknix-bsp-common")
sys.dont_write_bytecode = True  # keep __pycache__ out of the package dir
sys.path.insert(0, PKG)
import pocknix_perf as pp  # noqa: E402

errors = []


def check(cond, msg):
    if not cond:
        errors.append(msg)


def load_freqs(path):
    cpu, gpu = {}, []
    with open(path) as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue
            name, *vals = line.split()
            if name == "gpu":
                gpu = [int(v) for v in vals]
            else:
                cpu[name] = [int(v) for v in vals]
    return cpu, gpu


FACTORY_TEXT = open(os.path.join(PKG, "power-profiles.conf")).read()
try:
    factory = pp.load_factory(FACTORY_TEXT)
except pp.FactoryError as e:
    print(f"power-profiles.conf: {e}")
    sys.exit(1)

# Each family is checked as perfd sees it on that family: the factory plus its BSP's drop-ins.
DEVICES = os.path.join(ROOT, "devices")
socs, fams = [], []
for soc in sorted(os.listdir(DEVICES)):
    d = os.path.join(DEVICES, soc, "packages", f"pocknix-bsp-{soc}", "root/usr/share/pocknix/power-profiles.d")
    if not os.path.isdir(d):
        continue
    dropins = [(n, open(os.path.join(d, n)).read()) for n in sorted(os.listdir(d)) if n.endswith(".conf")]
    try:
        fam = pp.load_factory(FACTORY_TEXT, dropins)
    except pp.FactoryError as e:
        errors.append(f"{soc}: {e}")
        continue
    eff, warns = pp.layer_override(fam, None)
    check(not warns, f"{soc}: empty override produced warnings: {warns}")
    named = set(fam["tables"]) | {s for _, s in fam["overlays"]}
    check(named <= {soc.upper()}, f"{soc}: drop-ins name {sorted(named)}, the family is {soc.upper()}")
    if not named:
        continue
    socs.append(soc)
    fams.append(fam)
    try:
        cpu, gpu = load_freqs(os.path.join(DEVICES, soc, "freqs.txt"))
    except OSError:
        errors.append(f"{soc}: no devices/{soc}/freqs.txt to validate its tables against")
        continue
    up = soc.upper()
    for level, caps in fam["tables"].get(up, {}).items():
        for policy, khz in caps.items():
            check(policy in cpu, f"{up}.{level}: {policy} is not a cpufreq policy")
            check(khz in cpu.get(policy, []), f"{up}.{level}: {policy}={khz} is not an available frequency")
        check(set(caps) == set(cpu), f"{up}.{level}: covers {sorted(caps)}, SoC has {sorted(cpu)}")
    for pid in fam["order"]:
        t = pp.resolve(eff, pid, up, cpu, gpu)
        check(all(t["cpu_max"][p] in cpu[p] for p in cpu), f"{up}/{pid}: CPU cap off the OPP table")
        check(gpu[0] <= t["gpu_min"] <= t["gpu_max"] <= gpu[-1], f"{up}/{pid}: GPU range {t}")

# Drop-in semantics: hardware data only, and no section defined twice.
for name, text in [
    ("profile in a drop-in", "[profile.Performance]\ncpu_max = 0.5\n"),
    ("general in a drop-in", "[general]\ndefault_profile = Powersave\n"),
    ("duplicate table", "[underclock.X.small]\npolicy0 = 1\n\n[underclock.X.small]\npolicy0 = 2\n"),
]:
    try:
        pp.load_factory(FACTORY_TEXT, [("t.conf", text)])
        errors.append(f"drop-in '{name}' was accepted")
    except pp.FactoryError:
        pass

# Override semantics: a bad profile keeps its factory definition, a bad file is ignored.
# Run against a family with tables, so "changed the tables" can actually fail.
ref = fams[0] if fams else factory
soc = next(iter(ref["tables"]), "X")
pid = ref["order"][0]
before = copy.deepcopy({"profiles": ref["profiles"], "tables": ref["tables"]})
for name, text, want_warn in [
    ("bad value", f"[profile.{pid}]\ngpu_max = 7\n", True),
    ("unknown key", f"[profile.{pid}]\nturbo = yes\n", True),
    ("unknown profile", "[profile.nope]\nunderclock = small\n", True),
    ("syntax error", "[profile\nunderclock small\n", True),
    ("table override", f"[underclock.{soc}.small]\npolicy0 = 1\n", True),
    ("valid", f"[profile.{pid}]\nunderclock = small\n", False),
]:
    out, w = pp.layer_override(ref, text)
    check(bool(w) == want_warn, f"override '{name}': warnings {w}")
    if want_warn:
        check(out["profiles"] == before["profiles"], f"override '{name}' changed the profiles")
        check(out["tables"] == before["tables"], f"override '{name}' changed the tables")
    else:
        check(out["profiles"][pid]["underclock"] == "small", "valid override not applied")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"power profiles ok ({len(factory['order'])} profiles, tables for {', '.join(socs)})")
